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
| Default action | **Truncate** (override Vector's upstream `drop` default) | Partial data > no data; improves production observability; breaking change justified by observability gain |
| Truncation marker | `..TRUNCATED` suffix (11 bytes, hardcoded by Vector) | Clear indicator for downstream consumers; cannot be customized (Vector upstream) |
| Audit log handling | **Fuzzy JSON parser** in Rust (new Vector code) | Preserves structured audit fields (verb, user, objectRef) even when JSON is incomplete; critical for compliance/forensics |
| File-level truncation | Not supported (drop only) | Vector upstream limitation; file reader can only drop oversized lines, not truncate them |
| Configuration surface | Per-input tuning fields in CLF CR | Allows different limits for app/infra/audit logs; audit gets higher defaults (16MB vs 1MB) |
| Metrics granularity | Namespace/pod/container labels | Enables operators to identify sources of oversized logs for tuning |
| ViaQ envelope extension | `.structured_partial: true` field | Additive-only change; downstream systems can opt into handling partial logs |
| Vector buffer limit | Document 128MB hard limit | Upstream constraint; no code change, just user guidance |

## Architecture

### Configuration Flow

```
ClusterLogForwarder CR
  └── spec.inputs[].{type}.tuning
      ├── maxMessageSize: "32KB"
      ├── maxMergedLineBytes: "16MB"
      └── oversizedAction: "truncate"
         │
         ▼
    CLO reconciler
      └── Generates Vector config
          └── kubernetes_logs source
              ├── max_line_bytes: 32768
              ├── max_merged_line_bytes: 16777216
              └── max_merged_line_action: "truncate"  ← CLO sets this even if user omits it
```

**Key point:** When `oversizedAction` is omitted from the CLF CR, CLO explicitly sets Vector's `max_merged_line_action: "truncate"`. This overrides Vector's upstream default (`drop`) to prioritize data preservation.

### Truncation Processing Flow

```
Container log file
  │
  ▼
Vector file reader (max_line_bytes)
  ├── Line <= limit → pass through
  └── Line > limit → DROP (file-level truncation not supported)
      │
      ▼
Partial event merger (max_merged_line_bytes)
  ├── Merged line <= limit → emit normally
  └── Merged line > limit
      │
      ├─ oversizedAction: "drop" → discard, increment drop metric
      │
      └─ oversizedAction: "truncate"
         │
         ├─ Log type: application/infrastructure
         │    └── Truncate to limit, append ..TRUNCATED, emit
         │
         └─ Log type: audit
              └── Fuzzy JSON parser
                  ├── JSON detected → extract valid fields
                  │    └── Populate .structured, set .structured_partial: true
                  │
                  └── Not JSON / parse failed → raw truncated bytes
```

### Fuzzy JSON Parser (New Vector Code)

**Location:** `src/sources/kubernetes_logs/fuzzy_json_parser.rs` (new module in Vector fork)

**Integration:** Called from `partial_events_merger.rs` when:
- Truncation occurs (`merged line > max_merged_line_bytes`)
- Log type is `audit`
- Content starts with `{` or `[`

**Parser Strategy:**
1. Use streaming JSON parser (`serde_json::StreamDeserializer`) that can handle incomplete input
2. Extract fields as encountered, stop at first parse error
3. Special handling for known audit schema fields:
   - Top-level: `verb`, `requestURI`, `auditID`
   - User: `user.username`, `user.groups`
   - Object: `objectRef.resource`, `objectRef.namespace`, `objectRef.name`
   - Response: `responseStatus.code`, `responseStatus.message`
   - Metadata: `sourceIPs[0]`, `userAgent`
4. Return extracted fields as `serde_json::Value` map

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
  "structured": {
    "verb": "create",
    "user": {"username": "admin"},
    "objectRef": {"resource": "pods", "namespace": "default", "name": "test"}
  },
  "structured_partial": true,
  "kubernetes": {
    "namespace": "kube-apiserver",
    "pod": "kube-apiserver-123",
    "container": "kube-apiserver"
  },
  "@timestamp": "2026-09-21T10:00:00Z"
}
```

## Scope of Change

### Repos Affected

| Repo | Changes |
|---|---|
| **vector** (fork) | • Add fuzzy JSON parser module (`fuzzy_json_parser.rs`)<br>• Integrate into `partial_events_merger.rs`<br>• Add metrics: `audit_json_fuzzy_parse_attempts_total`, `audit_json_fuzzy_parse_success_total`<br>• Tests for fuzzy parser scenarios |
| **cluster-logging-operator** | • Extend CLF API: add `tuning.oversizedAction` to input specs<br>• Update Vector config generation: map CLF fields to Vector config<br>• Set `truncate` as default when field omitted<br>• Different defaults per input type (app/infra/audit)<br>• Update reconciler logic for `max_line_bytes` capping (rule 11) |
| **redhat-openshift-logging-workspace** | • This design doc<br>• Canonical spec (`.ai/spec/what/log-truncation.md`)<br>• Update `.ai/spec/README.md` with spec link |
| **redhat-openshift-logging-docs** | • User guide: truncation behavior, configuration examples<br>• Metrics guide: how to query truncated logs, identify sources<br>• Best practices: reducing log verbosity, sizing limits<br>• Audit log guidance: JSON truncation impact, `.structured_partial` field |

### API Changes (ClusterLogForwarder)

**New fields (all optional):**

```yaml
spec:
  inputs:
    - name: my-app
      type: application
      application:
        tuning:
          maxMessageSize: "32KB"           # default: 16KB
          maxMergedLineBytes: "1MB"        # default: 1MB
          oversizedAction: "truncate"      # default: "truncate" (set by CLO if omitted)
    
    - name: my-audit
      type: audit
      audit:
        tuning:
          maxMessageSize: "1MB"            # default: 1MB (higher than app/infra)
          maxMergedLineBytes: "16MB"       # default: 16MB (higher than app/infra)
          oversizedAction: "truncate"      # default: "truncate"
```

**Backward compatibility:**
- All fields optional; existing CRs work without changes
- Omitting fields uses defaults
- Default behavior changes from `drop` to `truncate` (behavioral change, but preserves more data)

## Migration Phases

### Phase 1: Vector Fuzzy JSON Parser (upstream contribution)
1. Implement `fuzzy_json_parser.rs` module in Vector
2. Add unit tests for partial JSON extraction
3. Integrate into `partial_events_merger.rs` for audit logs
4. Add new metrics
5. Submit PR to Vector upstream

### Phase 2: CLF API Extension
1. Add `tuning.oversizedAction` field to CLF API
2. Update CRD schema and validation
3. Generate API documentation
4. Add unit tests for API validation

### Phase 3: CLO Reconciler Updates
1. Map CLF `tuning` fields to Vector config
2. Implement default override logic (set `truncate` when omitted)
3. Implement `max_line_bytes` capping for drop mode (rule 11)
4. Add different defaults per input type
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
| Audit log structured field extraction | >80% of truncated audit logs have valid `.structured` fields | Real cluster test with Kubernetes audit logs |
| Metric accuracy | 100% of truncated logs counted in metrics | Compare log output count vs metric counter |
| Metric label correctness | Namespace/pod/container labels match source | Query metrics, cross-reference with log metadata |
| Performance impact (fuzzy parser) | <5ms p99 parse latency per truncated audit log | Benchmark with large JSON payloads |
| No data loss for logs within limits | 100% of logs <= limit pass through unchanged | Regression test suite |

## User Guidance (Documentation Requirements)

The product documentation must cover:

1. **Scope of limits** — `maxMessageSize` and `maxMergedLineBytes` apply to **originating log message only**, not the enriched ViaQ envelope
2. **Vector buffer constraint** — 128MB hard limit; keep `maxMergedLineBytes` well below (recommend max 64MB)
3. **Identifying sources of oversized logs** — PromQL examples:
   ```promql
   # Top 10 namespaces with most truncated logs
   topk(10, sum by (namespace) (rate(log_merged_lines_truncated_total[5m])))
   
   # Truncated logs by pod
   sum by (namespace, pod) (log_merged_lines_truncated_total)
   ```
4. **Reducing log verbosity** — application-side tuning strategies
5. **Audit log truncation** — explain fuzzy JSON parsing, `.structured_partial` field, compliance implications
6. **Truncation marker** — `..TRUNCATED` suffix for downstream query patterns
7. **Querying partial audit logs** — Loki/ES examples for `.structured_partial: true`

## Risks

| Risk | Mitigation |
|---|---|---|
| Fuzzy JSON parser bugs crash Vector | Extensive unit tests; parse errors logged at debug, not errors; fallback to raw bytes on failure |
| Performance impact of JSON parsing | Benchmark before merge; parser only runs on truncated audit logs (rare case); streaming parser is efficient |
| Behavioral change (drop → truncate) breaks downstream | Truncation preserves more data, not less; `.structured_partial` is additive-only; release notes document change |
| Downstream systems don't handle `.structured_partial` | Field is optional; systems that ignore it still get `.message` field with truncated content |
| Fuzzy parser extracts wrong fields | Parser validates JSON structure; only extracts complete key-value pairs; tests cover edge cases |
| Users set limits too high, hit 128MB Vector limit | Document recommended max (64MB); CLO could add validation warning for limits >64MB |
| Audit logs missing critical fields after truncation | Users can increase `maxMergedLineBytes` for audit; default is 16MB (large enough for most events) |

## Testing

### Unit Tests
- Fuzzy JSON parser: valid/invalid JSON, truncation at various points, nested objects/arrays
- CLF API validation: field types, defaults, enum values
- Vector config generation: CLF fields → Vector config mapping
- `max_line_bytes` capping logic (rule 11)

### Integration Tests
- End-to-end: CLF CR → Vector config → truncated log output
- Metrics: verify counters increment correctly with proper labels
- Fuzzy parser: real Kubernetes audit events truncated at various points
- ViaQ envelope: `.structured` and `.structured_partial` fields populated correctly

### Functional Tests (on cluster)
- Application logs: emit oversized logs, verify truncation marker
- Infrastructure logs: same as application
- Audit logs: trigger large audit events (pod create with big configmap), verify fuzzy parsing
- Metrics: scrape `/metrics`, verify `log_merged_lines_truncated_total` with labels
- Drop mode: set `oversizedAction: drop`, verify logs are dropped (not truncated)

### Performance Tests
- Fuzzy parser latency: benchmark with 1MB, 10MB, 100MB JSON payloads
- Truncation throughput: sustained rate of oversized logs, measure CPU/memory
- No regression: logs within limits have no performance change

## Open Questions

1. **Target release** — Which OpenShift Logging version? (6.7, 6.8?)
2. **Vector upstream acceptance** — Will Vector upstream accept fuzzy JSON parser PR, or must we maintain it in our fork?
3. **Validation warning for high limits** — Should CLO warn when `maxMergedLineBytes > 64MB` (approaching 128MB Vector limit)?
4. **Default `maxMergedLineBytes` for audit** — Is 16MB sufficient, or should it be higher (32MB, 64MB)?
5. **Fuzzy parser configurability** — Should users be able to disable fuzzy parsing for audit logs, or is it always-on when `oversizedAction: truncate`?

## Future Enhancements (Out of Scope)

- **File-level truncation** — Vector doesn't support truncating individual lines at the file reader level (only drop). Upstream feature request.
- **Custom truncation marker** — `..TRUNCATED` is hardcoded by Vector. Could be configurable in future.
- **Smart JSON truncation** — Attempt to close JSON structure gracefully (add `}` or `]`) instead of leaving it broken. Complex edge cases.
- **Configurable fuzzy parser fields** — Allow users to specify which audit fields to extract. Current implementation uses a fixed set.
- **Truncation for non-Kubernetes logs** — Currently only applies to merged partial events from Kubernetes container logs. Could extend to journal logs, receiver inputs, etc.
