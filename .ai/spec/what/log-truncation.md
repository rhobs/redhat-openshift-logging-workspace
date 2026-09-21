# Log Message Truncation

The collector supports truncating oversized log messages instead of dropping them silently. This preserves partial log content and improves observability when applications emit logs exceeding configured size limits. For structured logs (particularly JSON audit logs), a fuzzy parser attempts to extract valid fields from truncated content.

## Problem Statement

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Historically, the collector dropped oversized messages entirely, leading to silent data loss. This truncation feature provides an alternative: preserve the message content up to the configured limit, append a truncation marker, and emit metrics identifying the source.

Audit logs present a special challenge: they are typically JSON-formatted, and truncating in the middle of a JSON structure renders the log unparseable by downstream systems. To address this, the collector implements fuzzy JSON parsing to extract as many valid fields as possible from truncated audit logs.

## Behavioral Rules

### Message Size Limits

1. **`maxMessageSize`** applies to the **originating log message only** (the raw bytes read from the container log file or journal), not the enriched ViaQ envelope or other metadata added during processing.
2. The default `maxMessageSize` is 16KB for application and infrastructure container logs, and 1MB for audit logs.
3. Kubernetes container logs may be split into partial events by the container runtime. Vector automatically merges consecutive partial events into a single log record.
4. **`max_merged_line_bytes`** limits the size of the merged result after combining partial events. Defaults to 1MB for application/infrastructure logs and 16MB for audit logs.
5. Vector has a hard buffer chunk size limit of 128MB. Messages exceeding this limit cannot be processed regardless of `maxMessageSize` or `max_merged_line_bytes` configuration. This is an upstream Vector constraint.

### Truncation Behavior

6. When a merged log line exceeds `max_merged_line_bytes`, the truncation action determines the outcome: `drop` (discard the entire message) or `truncate` (keep the first N bytes up to the limit).7. When `oversizedAction` is not explicitly configured in the ClusterLogForwarder CR, the CLO sets Vector's `max_merged_line_action` to **`truncate`**. This differs from Vector's upstream default (`drop`) to prioritize data preservation and observability in production environments.8. When truncation is enabled and a merged line exceeds the limit:
   - The message is truncated to `max_merged_line_bytes` bytes.
   - A `..TRUNCATED` suffix (11 bytes) is appended to the truncated content if the limit is >= 11 bytes.
   - If the limit is < 11 bytes, the message is truncated to the limit without the suffix.
   - Any remaining partial events for the same log stream are discarded.
   - A metric counter is incremented (see Observability section).
   - A warning is logged by the collector.9. When the truncation action is `drop` and a merged line exceeds the limit:
   - The entire message is discarded.
   - A metric counter is incremented.
   - A warning is logged by the collector.10. Individual log lines exceeding `maxMessageSize` **at the file read level** are always dropped, regardless of the truncation action setting. File-level truncation is not currently supported.
### Interaction with max_line_bytes

11. When truncation action is `drop`, Vector's file reader `max_line_bytes` is capped to the smaller of `maxMessageSize` and `max_merged_line_bytes` to avoid wasted I/O reading lines that will be dropped during merge.12. When truncation action is `truncate`, individual lines up to `maxMessageSize` are allowed through the file reader so the merger can truncate the combined result. This means partial events up to `maxMessageSize` each are read and merged before truncation is applied.
### Fuzzy JSON Parsing for Audit Logs

13. When an audit log is truncated, the collector attempts to detect if the content is JSON by checking for a leading `{` or `[` character.14. If JSON is detected, a fuzzy parser attempts to extract valid JSON fields from the truncated bytes up to the truncation point. The parser:
    - Parses valid key-value pairs that are complete before the truncation point
    - Extracts key audit fields when present: `verb`, `user`, `objectRef`, `responseStatus`, `requestURI`, `sourceIPs`, `userAgent`, `auditID`
    - Handles nested objects and arrays up to the truncation boundary
    - Stops parsing at the first invalid/incomplete JSON token15. Successfully parsed JSON fields are stored in the ViaQ envelope's `.structured` field (or equivalent structured log field depending on log namespace).16. A `.structured_partial: true` field is added to the ViaQ envelope to indicate the structured data is incomplete due to truncation.17. The original truncated message bytes (with `..TRUNCATED` suffix) are preserved in the `.message` field for fallback/debugging.18. If fuzzy JSON parsing fails (malformed JSON, no valid fields extracted before truncation point), the log is treated as a raw truncated message:
    - No `.structured` field is populated
    - `.message` contains the truncated bytes with `..TRUNCATED` suffix
    - No `.structured_partial` marker is added19. Fuzzy JSON parsing only applies to **audit** log types. Application and infrastructure logs are not parsed for JSON structure during truncation.
### Truncated Content and ViaQ Envelope

20. Truncated log messages are normalized and enriched with ViaQ envelope metadata like any other log record (namespace, pod, container, timestamp, labels).21. For non-JSON or failed-parse truncated logs, the `.message` field contains the truncated bytes with the `..TRUNCATED` suffix. Downstream structured log parsing may fail.22. For successfully fuzzy-parsed audit logs, downstream consumers receive:
    - `.structured` field with extracted JSON fields
    - `.structured_partial: true` indicator
    - `.message` field with original truncated bytes
    - Standard ViaQ metadata (namespace, pod, container, timestamp)23. Downstream consumers (Loki, Elasticsearch, Splunk, etc.) are responsible for handling the `.structured_partial` indicator and incomplete message content appropriately.
## Configuration Surface

### Application and Infrastructure Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].application.tuning.maxMessageSize` | string (bytes) | `16384` (16KB) | Maximum size of a single log message from the container log file. |
| `spec.inputs[].application.tuning.maxMergedLineBytes` | string (bytes) | `1048576` (1MB) | Maximum size of a merged log line after combining Kubernetes partial events. |
| `spec.inputs[].application.tuning.oversizedAction` | enum | `truncate` | Action when a merged line exceeds `maxMergedLineBytes`: `drop` or `truncate`. |
| `spec.inputs[].infrastructure.tuning.maxMessageSize` | string (bytes) | `16384` (16KB) | Same as application, for infrastructure container logs. |
| `spec.inputs[].infrastructure.tuning.maxMergedLineBytes` | string (bytes) | `1048576` (1MB) | Same as application, for infrastructure container logs. |
| `spec.inputs[].infrastructure.tuning.oversizedAction` | enum | `truncate` | Same as application, for infrastructure container logs. |

### Audit Inputs

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.inputs[].audit.tuning.maxMessageSize` | string (bytes) | `1048576` (1MB) | Maximum size of a single audit log message from the container log file. |
| `spec.inputs[].audit.tuning.maxMergedLineBytes` | string (bytes) | `16777216` (16MB) | Maximum size of a merged audit log line. Higher default to accommodate large JSON audit events. |
| `spec.inputs[].audit.tuning.oversizedAction` | enum | `truncate` | Action when a merged line exceeds `maxMergedLineBytes`: `drop` or `truncate`. When `truncate`, fuzzy JSON parsing is attempted. |

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
          maxMessageSize: 32768          # 32KB individual line limit
          maxMergedLineBytes: 131072     # 128KB merged line limit
          oversizedAction: truncate      # Truncate instead of drop
    
    - name: my-audit-logs
      type: audit
      audit:
        sources:
          - kubeAPI
          - openshiftAPI
        tuning:
          maxMessageSize: 2097152        # 2MB individual line limit
          maxMergedLineBytes: 33554432   # 32MB merged line limit
          oversizedAction: truncate      # Truncate with fuzzy JSON parsing
  
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

24. The collector exposes a `log_merged_lines_truncated_total` counter metric (mapped from Vector's `k8s_merged_line_truncated_total`) for each truncated merged log line.25. The metric includes the following labels:
    - `namespace`: Kubernetes namespace of the source pod
    - `pod`: Pod name
    - `container`: Container name within the pod
    - `log_type`: `application`, `infrastructure`, or `audit`26. The collector exposes a `log_events_dropped_total` counter metric for dropped oversized messages (when `oversizedAction: drop` is used).27. The collector exposes an `audit_json_fuzzy_parse_attempts_total` counter for each fuzzy JSON parse attempt on truncated audit logs.28. The collector exposes an `audit_json_fuzzy_parse_success_total` counter for successful fuzzy JSON parses (at least one valid field extracted).29. All metrics are available at the collector's metrics endpoint (`/metrics`) and scraped by the cluster monitoring stack.
### Collector Logs

30. When a merged line is truncated, the collector logs a warning: `"Truncating frame larger than max_length. original_len=<size> max_length=<limit>"`.31. When a merged line is dropped (drop mode), the collector logs a warning: `"Discarding frame larger than max_length. buf_len=<size> max_length=<limit>"`.32. When fuzzy JSON parsing succeeds on a truncated audit log, the collector logs an info message: `"Fuzzy JSON parse extracted <N> fields from truncated audit log. audit_id=<id> namespace=<ns> pod=<pod>"`.33. When fuzzy JSON parsing fails on a truncated audit log, the collector logs a debug message: `"Fuzzy JSON parse failed for truncated audit log, falling back to raw bytes. namespace=<ns> pod=<pod>"`.
## User Guidance (Documentation Requirements)

The product documentation must include:

34. **Scope of limits**: `maxMessageSize` and `maxMergedLineBytes` apply to the **originating log message bytes only**, before ViaQ envelope enrichment. The final forwarded record size will be larger due to metadata.35. **Vector buffer constraint**: Vector has a hard 128MB buffer chunk size limit. Messages exceeding this limit cannot be processed. Users should keep `maxMergedLineBytes` well below 128MB. Recommended maximum: 64MB.36. **Identifying sources of oversized logs**: Use the `log_merged_lines_truncated_total` metric with namespace/pod/container labels to identify which applications are generating truncated logs. Provide PromQL query examples.37. **Reducing log verbosity**: Guide users on application-side tuning:
    - Configure application log levels (DEBUG → INFO → WARN)
    - Limit stack trace depth in error logs
    - Use structured logging to separate large payloads into separate fields
    - Split multi-line logs into separate events at the application layer38. **Audit log truncation and fuzzy parsing**: Explain that:
    - Audit logs are typically JSON-formatted and can be large (especially for create/update operations with full resource specs)
    - When truncated, fuzzy JSON parsing attempts to extract key audit fields (`verb`, `user`, `objectRef`, etc.)
    - Downstream queries should check for `.structured_partial: true` to identify incomplete audit events
    - Users can increase `maxMergedLineBytes` for audit logs to reduce truncation frequency39. **Truncation marker**: Truncated logs have a `..TRUNCATED` suffix appended to the `.message` field. Downstream queries/alerts should account for this suffix when pattern-matching log content.40. **Querying partial audit logs**: Provide examples of how to query for partial audit logs:
    - Loki: `{log_type="audit"} | json | structured_partial="true"`
    - Elasticsearch: Query for documents with `structured_partial: true` field
    - Explain that partial logs may be missing important fields like `responseStatus` if truncation occurred early
## Constraints

- The truncation feature depends on Vector v0.44.0 or later (PR #25567 merged) for the base truncation functionality.
- **Fuzzy JSON parsing requires new Vector code** (Rust implementation in kubernetes_logs source). This is new development work, not yet upstream.
- Truncation only applies to **merged partial log lines** from Kubernetes container logs. Individual log lines exceeding `maxMessageSize` at the file read level are always dropped (Vector does not support file-level truncation yet).
- The `..TRUNCATED` suffix is hardcoded by Vector and cannot be customized.
- Fuzzy JSON parsing is best-effort. Complex nested JSON structures may not parse correctly if truncation occurs mid-structure.
- The fuzzy parser only attempts to extract top-level and common audit fields. Custom audit policies with deeply nested or non-standard fields may not be fully captured.

## Migration and Compatibility

41. Upgrading to a version with this feature changes the **default behavior**: oversized merged lines are **truncated** instead of **dropped**. This is a behavioral change but preserves more data.42. Users who prefer the old drop behavior can explicitly set `oversizedAction: drop` in their input configuration.43. The configuration fields (`maxMessageSize`, `maxMergedLineBytes`, `oversizedAction`) are **optional**. If omitted, defaults apply. Existing ClusterLogForwarder CRs without these fields continue to work with the new truncate-by-default behavior.44. The `.structured_partial` field in the ViaQ envelope is a new field. Downstream systems that do not recognize this field will ignore it. No breaking changes to existing log schemas.
## Implementation Notes (for `how/` reference)

### Vector Configuration Mapping

- The CLF controller maps `spec.inputs[].application.tuning.oversizedAction` to Vector's `max_merged_line_action` config in the kubernetes_logs source.
- `maxMessageSize` maps to Vector's `max_line_bytes` (with conditional capping per rule 11).
- `maxMergedLineBytes` maps to Vector's `max_merged_line_bytes`.
- Different defaults are applied based on input type: application (1MB), infrastructure (1MB), audit (16MB).

### Fuzzy JSON Parser Implementation

- **Location**: New module in Vector's `src/sources/kubernetes_logs/fuzzy_json_parser.rs`
- **Integration point**: Called from `partial_events_merger.rs` when truncation occurs and log type is audit
- **Parser strategy**:
  - Use a streaming JSON parser (e.g., `serde_json::StreamDeserializer`) that can handle incomplete input
  - Extract fields as they are encountered, stop at first parse error
  - Special handling for known audit schema fields: extract `verb`, `user.username`, `objectRef.resource`, `objectRef.namespace`, `objectRef.name`, `responseStatus.code`, `requestURI`, `sourceIPs[0]`, `userAgent`, `auditID`
  - Return extracted fields as a `serde_json::Value` map
- **Error handling**: Parse failures are logged at debug level, not errors. Fallback to raw truncated bytes.

### Metrics Exposure

- Metrics are exposed via Vector's existing metrics endpoint; no custom exporter needed.
- The collector DaemonSet's ServiceMonitor scrapes the metrics with standard labels (namespace, pod, container derived from Vector's internal event metadata).
- New audit JSON parsing metrics (`audit_json_fuzzy_parse_attempts_total`, `audit_json_fuzzy_parse_success_total`) are added to Vector's internal events system.

### ViaQ Envelope Schema Extension

- Add optional `.structured_partial: bool` field to the ViaQ envelope schema
- Field is only present when fuzzy JSON parsing succeeds on a truncated log
- Field is omitted for non-truncated logs and for truncated logs where parsing failed
- No version bump required; this is an additive-only change
