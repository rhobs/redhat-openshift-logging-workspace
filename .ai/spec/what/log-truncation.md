# Log Message Truncation

The collector supports truncating oversized log messages instead of dropping them silently. This preserves partial log content and improves observability when applications emit logs exceeding configured size limits. For structured logs (particularly JSON audit logs), a fuzzy parser attempts to extract valid fields from truncated content.

## Problem Statement

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Historically, the collector dropped oversized messages entirely, leading to silent data loss. This truncation feature provides an alternative: preserve the message content up to the configured limit, append a truncation marker, and emit metrics identifying the source.

Audit logs present a special challenge: they are typically JSON-formatted, and truncating in the middle of a JSON structure renders the log unparseable by downstream systems. To address this, the collector implements fuzzy JSON parsing to extract as many valid fields as possible from truncated audit logs.

## Behavioral Rules

### Message Size Limits

1. **`maxMergedLineBytes`** limits the size of log messages after merging partial events. It applies to the **originating log message only** (the raw bytes read from the container log file or journal), not the enriched ViaQ envelope or other metadata added during processing.
2. The default `maxMergedLineBytes` is 1MB for application and infrastructure container logs, and 16MB for audit logs.
3. Kubernetes container logs may be split into partial events by the container runtime. Vector automatically merges consecutive partial events into a single log record before applying the size limit.
4. Vector has a hard buffer chunk size limit of 128MB. Messages exceeding this limit cannot be processed regardless of `maxMergedLineBytes` configuration. This is an upstream Vector constraint.

### Truncation Behavior

5. When a merged log line exceeds `maxMergedLineBytes`, the collector always truncates the message (keeps the first N bytes up to the limit). The CLO sets Vector's `max_merged_line_action` to `truncate` as a defensive mechanism. Dropping logs entirely is not exposed as a configuration option.
6. When a merged line exceeds the limit:
   - The message content is truncated to `maxMergedLineBytes - 11` bytes, and a `..TRUNCATED` suffix (11 bytes) is appended, so the total output size is exactly `maxMergedLineBytes`.
   - Any remaining partial events for the same log stream are discarded.
   - A metric counter is incremented (see Observability section).
   - A warning is logged by the collector.
7. Individual log lines exceeding `maxMergedLineBytes` **at the file read level** are always dropped. File-level truncation is not currently supported by Vector.

### File Reader Configuration

8. Vector's file reader `max_line_bytes` is set to `maxMergedLineBytes` to allow partial events to be read and merged before truncation is applied at the merge stage.

### Fuzzy JSON Parsing for Audit Logs

9. After truncation occurs, a Vector transform applies fuzzy JSON parsing to extract structured fields from truncated audit logs.
10. The fuzzy parser attempts to detect if the truncated content is JSON by checking for a leading `{` or `[` character.
11. If JSON is detected, the parser attempts to extract valid JSON fields from the truncated bytes up to the truncation point. The parser:
    - Parses valid key-value pairs that are complete before the truncation point
    - Extracts key audit fields when present: `verb` (what action), `user.username` (who), `objectRef.resource`, `objectRef.namespace`, `objectRef.name` (what resource), `responseStatus.code` (outcome), `requestURI`, `sourceIPs[0]`, `userAgent`, `auditID` (correlation)
    - These fields are the default set, selected based on analysis of Kubernetes audit event schema as the minimum viable set for forensic analysis and compliance queries
    - The list of priority fields is configurable via the Vector transform configuration, allowing teams to add or reorder fields based on their compliance requirements
    - Handles nested objects and arrays up to the truncation boundary
    - Stops parsing at the first invalid/incomplete JSON token
12. Successfully parsed JSON fields are merged into the root level of the log event (not a separate `.structured` field). This matches the current behavior for audit logs where JSON fields are parsed into the root.
13. A `structured_partial` field (boolean) is added to the root level to indicate the structured data is incomplete due to truncation.
14. The original truncated message bytes (with `..TRUNCATED` suffix) are preserved in the `message` field for fallback/debugging.
15. If fuzzy JSON parsing fails (malformed JSON, no valid fields extracted before truncation point), the log is treated as a raw truncated message:
    - No parsed fields are added to the root
    - `message` field contains the truncated bytes with `..TRUNCATED` suffix
    - No `structured_partial` marker is added
16. Fuzzy JSON parsing only applies to **audit** log types. Application and infrastructure logs are not parsed for JSON structure during truncation.

### Truncated Content and ViaQ Envelope

17. Truncated log messages are normalized and enriched with ViaQ envelope metadata like any other log record (namespace, pod, container for application/infrastructure logs; hostname/node for audit logs; timestamp, labels).
18. For non-JSON or failed-parse truncated logs, the `message` field contains the truncated bytes with the `..TRUNCATED` suffix. Downstream structured log parsing may fail.
19. For successfully fuzzy-parsed audit logs, downstream consumers receive:
    - Extracted JSON fields merged into the root level of the event
    - `structured_partial: true` field at root level
    - `message` field with original truncated bytes
    - Standard ViaQ metadata (hostname/node for audit logs, timestamp)
20. Downstream consumers (Loki, Elasticsearch, Splunk, etc.) are responsible for handling the `structured_partial` indicator and incomplete message content appropriately.

## Configuration Surface

### Application and Infrastructure Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].application.tuning.maxMergedLineBytes` | string (bytes) | `1048576` (1MB) | Maximum size of a log message after merging Kubernetes partial events. Messages exceeding this limit are truncated. |
| `spec.inputs[].infrastructure.tuning.maxMergedLineBytes` | string (bytes) | `1048576` (1MB) | Same as application, for infrastructure container logs. |

### Audit Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].audit.tuning.maxMergedLineBytes` | string (bytes) | `16777216` (16MB) | Maximum size of an audit log message after merging partial events. Higher default to accommodate large JSON audit events. Truncated audit logs are processed by the fuzzy JSON parser. |

### Example Configuration

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  inputs:
    - name: my-app-logs
      type: application
      application:
        selector:
          matchLabels:
            app: my-verbose-app
        tuning:
          maxMergedLineBytes: 131072     # 128KB limit (default is 1MB)
    
    - name: my-audit-logs
      type: audit
      audit:
        sources:
          - kubeAPI
          - openshiftAPI
        tuning:
          maxMergedLineBytes: 33554432   # 32MB limit (default is 16MB)
  
  pipelines:
    - name: forward-app-logs
      inputRefs:
        - my-app-logs
      outputRefs:
        - default-lokistack
    
    - name: forward-audit-logs
      inputRefs:
        - my-audit-logs
      outputRefs:
        - default-lokistack
```

## Observability

### Metrics

21. The collector exposes a `message_truncated_total` counter metric for each truncated log message.
22. The metric includes the following labels:
    - For application/infrastructure logs: `namespace`, `pod`, `container`, `log_type`
    - For audit logs: `hostname` (node name), `log_type`
23. The collector exposes an `audit_json_fuzzy_parse_attempts_total` counter for each fuzzy JSON parse attempt on truncated audit logs (labeled by `hostname`).
24. The collector exposes an `audit_json_fuzzy_parse_success_total` counter for successful fuzzy JSON parses (at least one valid field extracted, labeled by `hostname`).
25. All metrics are available at the collector's metrics endpoint (`/metrics`) and scraped by the cluster monitoring stack.

### Collector Logs

26. When a message is truncated, the collector logs a warning: `"Truncating frame larger than max_length. original_len=<size> max_length=<limit>"`.
27. When fuzzy JSON parsing succeeds on a truncated audit log, the collector logs an info message: `"Fuzzy JSON parse extracted <N> fields from truncated audit log. audit_id=<id> hostname=<node>"`.
28. When fuzzy JSON parsing fails on a truncated audit log, the collector logs a debug message: `"Fuzzy JSON parse failed for truncated audit log, falling back to raw bytes. hostname=<node>"`.

## User Guidance (Documentation Requirements)

The product documentation must include:

29. **Scope of limits**: `maxMergedLineBytes` applies to the **originating log message bytes only**, before ViaQ envelope enrichment. The final forwarded record size will be larger due to metadata.
30. **Vector buffer constraint**: Vector has a hard 128MB buffer chunk size limit. Messages exceeding this limit cannot be processed. Users should keep `maxMergedLineBytes` well below 128MB. Recommended maximum: 64MB.
31. **Identifying sources of oversized logs**: Use the `message_truncated_total` metric to identify which applications/nodes are generating truncated logs. Provide PromQL query examples:
    - Application logs: `sum by (namespace, pod) (message_truncated_total{log_type="application"})`
    - Audit logs: `sum by (hostname) (message_truncated_total{log_type="audit"})`
32. **Reducing log verbosity**: Guide users on application-side tuning:
    - Configure application log levels (DEBUG → INFO → WARN)
    - Limit stack trace depth in error logs
    - Use structured logging to separate large payloads into separate fields
    - Split multi-line logs into separate events at the application layer
33. **Audit log truncation and fuzzy parsing**: Explain that:
    - Audit logs are typically JSON-formatted and can be large (especially for create/update operations with full resource specs)
    - When truncated, fuzzy JSON parsing attempts to extract key audit fields (`verb`, `user`, `objectRef`, etc.) and merge them into the root level
    - Downstream queries should check for `structured_partial: true` to identify incomplete audit events
    - Users can increase `maxMergedLineBytes` for audit logs to reduce truncation frequency
34. **Truncation marker**: Truncated logs have a `..TRUNCATED` suffix appended to the `message` field. Downstream queries/alerts should account for this suffix when pattern-matching log content.
35. **Querying partial audit logs**: Provide examples of how to query for partial audit logs:
    - Loki: `{log_type="audit"} | json | structured_partial="true"`
    - Elasticsearch: Query for documents with `structured_partial: true` field
    - Explain that partial logs may be missing important fields like `responseStatus` if truncation occurred early

## Constraints

- The truncation feature depends on Vector v0.54.0-rh or later (upstream PR #25567 merged in v0.58.0, cherry-picked into the Red Hat fork).
- **Fuzzy JSON parsing requires new Vector code** (Rust transform implementation). This is new development work in the Red Hat fork of Vector, not proposed for upstream.
- Truncation only applies to **merged partial log lines** from Kubernetes container logs. Individual log lines exceeding `maxMergedLineBytes` at the file read level are always dropped (Vector does not support file-level truncation yet).
- The `..TRUNCATED` suffix is hardcoded by Vector and cannot be customized.
- Fuzzy JSON parsing is best-effort. Complex nested JSON structures may not parse correctly if truncation occurs mid-structure.
- The fuzzy parser extracts a configurable set of audit fields with sensible defaults (see rule 11). Custom audit policies with deeply nested or non-standard fields may not be fully captured.

## Migration and Compatibility

36. Upgrading to a version with this feature changes the **default behavior**: oversized messages are **truncated** instead of **dropped silently**. This is a behavioral change that preserves more data and improves observability.
37. The current behavior (silent drops) cannot be restored via configuration. Truncation is always enabled as a defensive mechanism.
38. The `maxMergedLineBytes` configuration field is **optional**. If omitted, defaults apply (1MB for application/infrastructure, 16MB for audit). Existing ClusterLogForwarder CRs without this field continue to work with the defaults.
39. The `structured_partial` field (for fuzzy-parsed audit logs) is a new field added to the root level. Downstream systems that do not recognize this field will ignore it. No breaking changes to existing log schemas.

## Implementation Notes (for `how/` reference)

### Vector Configuration Mapping

- The CLF controller maps `spec.inputs[].{type}.tuning.maxMergedLineBytes` to Vector's `max_merged_line_bytes` config in the kubernetes_logs source.
- The CLF controller sets Vector's `max_merged_line_action` to `truncate` (hardcoded, not user-configurable).
- Vector's `max_line_bytes` (file reader) is set to the same value as `max_merged_line_bytes` to allow partial events through for merging.
- Different defaults are applied based on input type: application (1MB), infrastructure (1MB), audit (16MB).

### Fuzzy JSON Parser Implementation

- **Location**: New Vector transform in `src/transforms/audit_json_fuzzy_parser.rs` (Red Hat fork)
- **Integration point**: Inserted into the Vector pipeline after the kubernetes_logs source and partial event merger, before the ViaQ normalizer
- **Activation**: Only applied to audit log streams (filtered by log type metadata)
- **Parser strategy**:
  - Use a streaming JSON parser (e.g., `serde_json::StreamDeserializer`) that can handle incomplete input
  - Extract fields as they are encountered, stop at first parse error
  - Special handling for known audit schema fields: extract `verb`, `user.username`, `objectRef.resource`, `objectRef.namespace`, `objectRef.name`, `responseStatus.code`, `requestURI`, `sourceIPs[0]`, `userAgent`, `auditID`
  - Merge extracted fields into the root level of the event (not a nested `.structured` object)
  - Add `structured_partial: true` field to root when parsing succeeds
  - Return extracted fields as a flat map merged into the event root
- **Error handling**: Parse failures are logged at debug level, not errors. Fallback to raw truncated bytes without modification.

### Metrics Exposure

- Metrics are exposed via Vector's existing metrics endpoint; no custom exporter needed.
- The collector DaemonSet's ServiceMonitor scrapes the metrics.
- Metric labels differ by log type:
  - Application/infrastructure: namespace, pod, container
  - Audit: hostname (node name)
- New metrics added to Vector's internal events system:
  - `message_truncated_total` (replaces Vector's `k8s_merged_line_truncated_total`)
  - `audit_json_fuzzy_parse_attempts_total`
  - `audit_json_fuzzy_parse_success_total`

### Event Schema Changes

- Add optional `structured_partial: bool` field to the root level of audit log events
- Field is only present when fuzzy JSON parsing succeeds on a truncated audit log
- Field is omitted for non-truncated logs and for truncated logs where parsing failed
- Parsed audit fields are merged into the root level (matching existing audit log parsing behavior)
- No ViaQ envelope version bump required; this is an additive-only change
