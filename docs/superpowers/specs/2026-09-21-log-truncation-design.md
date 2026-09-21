# Log Message Truncation Design

**Date:** 2026-09-21
**Status:** Draft
**Canonical spec:** `.ai/spec/what/log-truncation.md`
**Jira:** [LOG-9672](https://redhat.atlassian.net/browse/LOG-9672)

## Summary

Add support for truncating oversized log messages instead of silently dropping them, preserving partial log content and improving observability when applications emit logs exceeding configured size limits. For structured logs (particularly JSON audit logs), implement a fuzzy JSON parser to extract as many valid fields as possible from truncated content.

## Problem

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Currently, the collector **silently drops** oversized messages entirely, leading to:

1. **Silent data loss** — no indication that logs were discarded
2. **Poor observability** — operators don't know which applications are producing oversized logs
3. **All-or-nothing failure** — even if 99% of the log message is valid, the entire message is lost
4. **Critical audit log loss** — JSON audit logs can be large (especially create/update operations with full resource specs), and dropping them entirely creates compliance gaps

The impact compounds for audit logs: they are JSON-formatted, and even a truncated audit event contains valuable forensic data (verb, user, objectRef, timestamp) if we can extract it.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Default action | **Always truncate** (no user configuration) | Partial data > no data; defensive mechanism; no justification for allowing admins to prefer complete data loss |
| Truncation marker | `..TRUNCATED` suffix (11 bytes, hardcoded by Vector) | Clear indicator for downstream consumers; cannot be customized (Vector upstream) |
| Audit log handling | **Fuzzy JSON parser** as Vector transform (new code in RH fork) | Preserves structured audit fields (verb, user, objectRef) even when JSON is incomplete; critical for compliance/forensics; transform is cleaner separation than in-source parsing |
| File-level truncation | Not supported (drop only) | Vector upstream limitation; file reader can only drop oversized lines, not truncate them |
| Configuration surface | Single `maxMergedLineBytes` field per input | Simplified from dual max_line + max_merged; avoids confusion; audit gets higher default (16MB vs 1MB) |
| Metrics granularity | Namespace/pod/container for app/infra; hostname for audit | Enables operators to identify sources of oversized logs; audit logs are node-scoped not pod-scoped |
| Parsed field target | Merged into root level (not `.structured` object) | Matches existing audit log parsing behavior; no special nesting |
| Vector buffer limit | Document 128MB hard limit | Upstream constraint; no code change, just user guidance |

## Architecture

### Configuration Flow

```
ClusterLogForwarder CR
  └── spec.inputs[].{type}.tuning
      └── maxMergedLineBytes: "16MB"  (optional, defaults: 1MB app/infra, 16MB audit)
         │
         ▼
    CLO reconciler
      └── Generates Vector config
          └── kubernetes_logs source
              ├── max_line_bytes: 16777216  (same as max_merged_line_bytes)
              ├── max_merged_line_bytes: 16777216
              └── max_merged_line_action: "truncate"  ← Always set by CLO (not user-configurable)
```

**Key point:** CLO always sets Vector's `max_merged_line_action: "truncate"`. There is no user-facing `oversizedAction` configuration — truncation is always enabled as a defensive mechanism.

### Truncation Processing Flow

```
Container log file
  │
  ▼
Vector file reader (max_line_bytes = max_merged_line_bytes)
  ├── Line <= limit → pass through
  └── Line > limit → DROP (file-level truncation not supported)
      │
      ▼
Partial event merger (max_merged_line_bytes, action=truncate always)
  ├── Merged line <= limit → emit normally
  └── Merged line > limit → truncate to limit, append ..TRUNCATED, emit
      │
      ▼
Fuzzy JSON parser transform (audit logs only)
  ├── Log type: application/infrastructure → pass through unchanged
  │
  └── Log type: audit + contains ..TRUNCATED
      ├── JSON detected → extract valid fields, merge to root, add structured_partial: true
      └── Not JSON / parse failed → pass through unchanged
```

### Fuzzy JSON Parser (New Vector Transform)

**Location:** `src/transforms/audit_json_fuzzy_parser.rs` (new transform in Red Hat Vector fork)

**Integration:** Inserted into Vector pipeline after kubernetes_logs source and merger, before ViaQ normalizer. Applied only to audit log streams (filtered by log type metadata).

**Parser Strategy:**
1. Trigger: Only runs on audit logs with `..TRUNCATED` suffix in `message` field
2. Detection: Check if truncated content starts with `{` or `[`
3. Parse: Use streaming JSON parser (`serde_json::StreamDeserializer`) that handles incomplete input
4. Extract: Fields as encountered, stop at first parse error. Priority fields based on forensic analysis value:
   - What: `verb` (action type)
   - Who: `user.username`
   - Target: `objectRef.resource`, `objectRef.namespace`, `objectRef.name`
   - Outcome: `responseStatus.code`
   - Context: `requestURI`, `sourceIPs[0]`, `userAgent`, `auditID` (correlation)
5. Merge: Extracted fields into event root level (not nested object)
6. Mark: Add `structured_partial: true` to root when extraction succeeds
7. Return: Modified event with parsed fields merged in

**Error Handling:**
- Parse failures logged at debug level (not errors)
- Fallback to raw truncated bytes (standard truncation behavior)
- No panic/crash on malformed JSON

### ViaQ Envelope Extension

**Before (normal log):**
```json
{
  "message": "full log message here",
  "kubernetes": {
    "namespace": "my-app",
    "pod": "pod-123",
    "container": "app"
  },
  "@timestamp": "2026-09-21T10:00:00Z"
}
```

**After (truncated application log):**
```json
{
  "message": "partial log message up to limit..TRUNCATED",
  "kubernetes": {
    "namespace": "my-app",
    "pod": "pod-123",
    "container": "app"
  },
  "@timestamp": "2026-09-21T10:00:00Z"
}
```

**After (truncated audit log with fuzzy parse success):**
```json
{
  "message": "truncated JSON bytes..TRUNCATED",
  "verb": "create",
  "user": {"username": "admin"},
  "objectRef": {"resource": "pods", "namespace": "default", "name": "test"},
  "structured_partial": true,
  "hostname": "node-1.example.com",
  "@timestamp": "2026-09-21T10:00:00Z"
}
```
Note: Parsed fields are merged into root, not nested in a `structured` object. This matches existing audit log parsing behavior.

## Scope of Change

### Repos Affected

| Repo | Changes |
|---|---|
| **vector** (fork) | • Add fuzzy JSON parser transform (`audit_json_fuzzy_parser.rs`)<br>• Add metrics: `message_truncated_total`, `audit_json_fuzzy_parse_attempts_total`, `audit_json_fuzzy_parse_success_total`<br>• Tests for transform scenarios |
| **cluster-logging-operator** | • Extend CLF API: add `tuning.maxMergedLineBytes` to input specs<br>• Update Vector config generation: map CLF field to Vector config, hardcode `max_merged_line_action: truncate`<br>• Different defaults per input type (app/infra: 1MB, audit: 16MB)<br>• Set `max_line_bytes` = `max_merged_line_bytes` to allow partial events through |
| **redhat-openshift-logging-workspace** | • This design doc<br>• Canonical spec (`.ai/spec/what/log-truncation.md`)<br>• Update `.ai/spec/README.md` with spec link |
| **redhat-openshift-logging-docs** | • User guide: truncation behavior, configuration examples<br>• Metrics guide: how to query truncated logs, identify sources<br>• Best practices: reducing log verbosity, sizing limits<br>• Audit log guidance: JSON truncation impact, `structured_partial` field |

### API Changes (ClusterLogForwarder)

**New field (optional):**

```yaml
spec:
  inputs:
    - name: my-app
      type: application
      application:
        tuning:
          maxMergedLineBytes: "128KB"      # default: 1MB
    
    - name: my-audit
      type: audit
      audit:
        tuning:
          maxMergedLineBytes: "32MB"       # default: 16MB
```

**Backward compatibility:**
- Field is optional; existing CRs work without changes
- Omitting field uses defaults (1MB for app/infra, 16MB for audit)
- Default behavior changes from silent drop to truncate (behavioral change, but preserves more data and improves observability)

## Migration Phases

### Phase 1: Vector Fuzzy JSON Parser Transform (Red Hat fork)
1. Implement `audit_json_fuzzy_parser.rs` transform in Vector fork
2. Add unit tests for partial JSON extraction
3. Register transform in Vector's transform registry
4. Add new metrics (`message_truncated_total`, `audit_json_fuzzy_parse_*`)
5. This stays in RH fork; not proposed upstream

### Phase 2: CLF API Extension
1. Add `tuning.maxMergedLineBytes` field to CLF API
2. Update CRD schema and validation
3. Generate API documentation
4. Add unit tests for API validation

### Phase 3: CLO Reconciler Updates
1. Map CLF `tuning.maxMergedLineBytes` to Vector config
2. Hardcode `max_merged_line_action: truncate` in generated Vector config
3. Set `max_line_bytes` = `max_merged_line_bytes` to allow partial events through
4. Add different defaults per input type (1MB app/infra, 16MB audit)
5. Integration tests: CLF CR → Vector config verification

### Phase 4: Metrics and Observability
1. Verify Vector metrics are exposed correctly
2. Update ServiceMonitor for collector DaemonSet
3. Test metrics scraping with namespace/pod/container labels
4. Add example PromQL queries to docs

### Phase 5: Documentation
1. User guide: configuration examples, use cases
2. Metrics guide: querying truncated logs, dashboards
3. Best practices: tuning limits, reducing verbosity
4. Audit log guidance: `.structured_partial` handling, compliance impact
5. Release notes: behavior change from drop to truncate

### Phase 6: Validation
1. Test on cluster with realistic workloads
2. Verify audit log fuzzy parsing with various Kubernetes audit events
3. Measure metrics accuracy and label correctness
4. Performance testing: impact of fuzzy parser on CPU/memory

## Success Metrics

| Metric | Target | Validation |
|---|---|---|
| Truncated logs preserved (vs dropped) | 100% of logs <= limit preserved | Functional test: emit oversized logs, verify truncated output |
| Audit log structured field extraction | >80% of truncated audit logs have valid parsed fields at root | Real cluster test with Kubernetes audit logs |
| Metric accuracy | 100% of truncated logs counted in metrics | Compare log output count vs metric counter |
| Metric label correctness | Namespace/pod/container labels match source for app/infra; hostname label matches source node for audit | Query metrics, cross-reference with log metadata |
| Performance impact (fuzzy parser) | <5ms p99 parse latency per truncated audit log | Benchmark with large JSON payloads |
| No data loss for logs within limits | 100% of logs <= limit pass through unchanged | Regression test suite |

## User Guidance (Documentation Requirements)

The product documentation must cover:

1. **Scope of limits** — `maxMergedLineBytes` applies to **originating log message only**, not the enriched ViaQ envelope
2. **Vector buffer constraint** — 128MB hard limit; keep `maxMergedLineBytes` well below (recommend max 64MB)
3. **Identifying sources of oversized logs** — PromQL examples:
   ```promql
   # Top 10 namespaces with most truncated app logs
   topk(10, sum by (namespace) (rate(message_truncated_total{log_type="application"}[5m])))
   
   # Truncated audit logs by node
   sum by (hostname) (message_truncated_total{log_type="audit"})
   ```
4. **Reducing log verbosity** — application-side tuning strategies
5. **Audit log truncation** — explain fuzzy JSON parsing, root-level `structured_partial` field, compliance implications
6. **Truncation marker** — `..TRUNCATED` suffix for downstream query patterns
7. **Querying partial audit logs** — Loki/ES examples for `structured_partial: true`

## Risks

| Risk | Mitigation |
|---|---|---|
| Fuzzy JSON parser bugs crash Vector | Extensive unit tests; parse errors logged at debug, not errors; fallback to raw bytes on failure |
| Performance impact of JSON parsing | Benchmark before merge; transform only runs on truncated audit logs (rare case); streaming parser is efficient |
| Behavioral change (drop → truncate) breaks downstream | Truncation preserves more data, not less; `structured_partial` is additive-only; release notes document change |
| Downstream systems don't handle `structured_partial` | Field is optional; systems that ignore it still get `message` field and parsed fields at root |
| Fuzzy parser extracts wrong fields | Parser validates JSON structure; only extracts complete key-value pairs; tests cover edge cases |
| Users set limits too high, hit 128MB Vector limit | Document recommended max (64MB); CLO could add validation warning for limits >64MB |
| Audit logs missing critical fields after truncation | Users can increase `maxMergedLineBytes` for audit; default is 16MB (large enough for most events) |
| No way to revert to old drop behavior | Acceptable tradeoff; truncation is strictly better for observability; no valid use case for preferring silent drops |

## Testing

### Unit Tests
- Fuzzy JSON parser: valid/invalid JSON, truncation at various points, nested objects/arrays
- CLF API validation: field types, defaults, enum values
- Vector config generation: CLF fields → Vector config mapping
- `max_line_bytes` = `max_merged_line_bytes` configuration logic

### Integration Tests
- End-to-end: CLF CR → Vector config → truncated log output
- Metrics: verify counters increment correctly with proper labels
- Fuzzy parser: real Kubernetes audit events truncated at various points
- ViaQ envelope: parsed fields merged into root and `structured_partial` flag set correctly

### Functional Tests (on cluster)
- Application logs: emit oversized logs, verify truncation marker
- Infrastructure logs: same as application
- Audit logs: trigger large audit events (pod create with big configmap), verify fuzzy parsing
- Metrics: scrape `/metrics`, verify `message_truncated_total` with correct labels per log type

### Performance Tests
- Fuzzy parser latency: benchmark with 1MB, 10MB, 100MB JSON payloads
- Truncation throughput: sustained rate of oversized logs, measure CPU/memory
- No regression: logs within limits have no performance change

## Open Questions

1. **Target release** — Which OpenShift Logging version? (6.7, 6.8?)
2. **Validation warning for high limits** — Should CLO warn when `maxMergedLineBytes > 64MB` (approaching 128MB Vector limit)?
3. **Default `maxMergedLineBytes` for audit** — Is 16MB sufficient, or should it be higher (32MB, 64MB)?

### Resolved

- **Vector upstream acceptance** — Fuzzy JSON parser stays in RH fork, not proposed upstream.
- **Fuzzy parser configurability** — Always-on for audit logs when truncation occurs. No user toggle.
- **oversizedAction configuration** — Removed. Truncation is always enabled; no drop option exposed.

## Future Enhancements (Out of Scope)

- **File-level truncation** — Vector doesn't support truncating individual lines at the file reader level (only drop). Upstream feature request.
- **Custom truncation marker** — `..TRUNCATED` is hardcoded by Vector. Could be configurable in future.
- **Smart JSON truncation** — Attempt to close JSON structure gracefully (add `}` or `]`) instead of leaving it broken. Complex edge cases.
- **CLF-level fuzzy parser field configuration** — Expose the priority fields list through the ClusterLogForwarder CR so users don't need to edit Vector config directly.
- **Truncation for non-Kubernetes logs** — Currently only applies to merged partial events from Kubernetes container logs. Could extend to journal logs, receiver inputs, etc.
