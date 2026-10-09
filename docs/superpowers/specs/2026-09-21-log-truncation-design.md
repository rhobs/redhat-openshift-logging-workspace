# Log Message Truncation Design

**Date:** 2026-09-21
**Status:** Draft
**Canonical spec:** `.ai/spec/what/log-truncation.md`
**Jira:** [LOG-9672](https://redhat.atlassian.net/browse/LOG-9672) (spike), [LOG-9459](https://redhat.atlassian.net/browse/LOG-9459) (completed via upstream)

## Summary

Add support for truncating oversized log messages instead of silently dropping them, preserving partial log content and improving observability when applications emit logs exceeding configured size limits. For structured logs (particularly JSON audit logs), implement a fuzzy JSON parser to extract as many valid fields as possible from truncated content.

**Implementation Status:**
- ✅ **LOG-9459 (Vector truncation support)**: Completed via cherry-pick of upstream Vector PR [#25567](https://github.com/vectordotdev/vector/pull/25567). Vector now supports `max_merged_line_action: truncate` alongside the existing `drop` behavior.
- 🔄 **This spec (LOG-9672)**: Defines how OpenShift Logging **integrates** the upstream Vector feature and adds **new fork-specific work** (fuzzy JSON parser for audit logs).

## Problem

When container applications emit very long log lines or Kubernetes partial log events merge into messages exceeding size limits, the collector must decide how to handle them. Currently, the collector **silently drops** oversized messages entirely, leading to:

1. **Silent data loss** — no indication that logs were discarded
2. **Poor observability** — operators don't know which applications are producing oversized logs
3. **All-or-nothing failure** — even if 99% of the log message is valid, the entire message is lost
4. **Critical audit log loss** — JSON audit logs can be large (especially create/update operations with full resource specs), and dropping them entirely creates compliance gaps

The impact compounds for audit logs: they are JSON-formatted, and even a truncated audit event contains valuable forensic data (verb, user, objectRef, timestamp) if we can extract it.

## Relationship to LOG-9459

[LOG-9459](https://redhat.atlassian.net/browse/LOG-9459) added the **upstream Vector truncation capability** by cherry-picking [Vector PR #25567](https://github.com/vectordotdev/vector/pull/25567). That work provides:
- ✅ `max_merged_line_action: truncate` configuration option in Vector's `kubernetes_logs` source
- ✅ `..TRUNCATED` suffix appended to truncated messages
- ✅ Metrics for truncated messages
- ✅ Both `drop` (default) and `truncate` behaviors available at the Vector config level

**This spec (LOG-9672) builds on that foundation** by defining:
1. **OpenShift Logging integration**: How CLO exposes this feature through the ClusterLogForwarder API
2. **Product decision**: OpenShift Logging always sets `max_merged_line_action: truncate` (opinionated choice to preserve data)
3. **New fork-specific work**: Fuzzy JSON parser for audit logs (not in upstream Vector, specific to OpenShift Logging's audit log handling requirements)

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Default action | **Always truncate** (no user configuration) | Partial data > no data; defensive mechanism; no justification for allowing admins to prefer complete data loss |
| Truncation marker | `..TRUNCATED` suffix (11 bytes, hardcoded by Vector) | Clear indicator for downstream consumers; cannot be customized (Vector upstream) |
| Audit log handling | **Fuzzy JSON parser** as Vector transform (new code in RH fork) | Preserves structured audit fields (verb, user, objectRef) even when JSON is incomplete; critical for compliance/forensics; transform is cleaner separation than in-source parsing |
| File-level truncation | Not supported (drop only) | Vector upstream limitation; file reader can only drop oversized lines, not truncate them |
| Configuration surface | Single `maxMergedLineBytes` field per input | Simplified from dual max_line + max_merged; avoids confusion; audit may get higher default than app/infra (TBD) |
| Metrics granularity | Namespace/pod/container for app/infra; hostname for audit | Enables operators to identify sources of oversized logs; audit logs are node-scoped not pod-scoped |
| Parsed field target | Merged into root level (not `.structured` object) | Matches existing audit log parsing behavior; no special nesting |
| Vector buffer limit | Document 128MB hard limit | Upstream constraint; no code change, just user guidance |

## Architecture

### Configuration Flow

```
ClusterLogForwarder CR
  └── spec.inputs[].{type}.tuning
      └── maxMergedLineBytes: "2MB"  (optional, defaults TBD)
         │
         ▼
    CLO reconciler
      └── Generates Vector config
          └── kubernetes_logs source
              ├── max_line_bytes: 2097152  (same as max_merged_line_bytes)
              ├── max_merged_line_bytes: 2097152
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

**Edge Cases and Expected Behavior:**

| Truncation Point | Example | Expected Behavior | Success Criteria |
|------------------|---------|-------------------|------------------|
| Mid-key | `{"verb": "create", "use` | Extract `{"verb": "create"}`, ignore incomplete key | ✅ Partial success |
| Mid-value (string) | `{"verb": "cre` | No fields extracted (first field incomplete) | ❌ Fallback to raw bytes |
| Mid-value (number) | `{"responseStatus": {"code": 20` | Extract fields before incomplete value | ✅ Partial success |
| Mid-nested-object | `{"user": {"username": "ad` | Extract `user` object with available fields | ✅ Partial success |
| Mid-array | `{"sourceIPs": ["10.0.0.` | Extract fields before array, skip incomplete array | ✅ Partial success |
| Between key-value | `{"verb":` | No fields extracted | ❌ Fallback to raw bytes |
| Escaped string | `{"message": "User: \"Adm` | Extract fields before incomplete escaped string | ✅ Partial success |
| Unicode mid-char | `{"user": "Müll` (mid-`ü`) | Parser handles as invalid UTF-8, stops parsing | ⚠️ May extract prior fields or fail |
| After closing brace | `{"verb": "create"}extra` | Extract complete object, ignore trailing content | ✅ Full success |

**Success target:** >80% of real-world truncated audit logs extract ≥1 meaningful field (verb, user, objectRef, responseStatus)

**Parser strategy:**
- Streaming/incremental parsing stops at first parse error
- Successfully parsed fields before error point are extracted
- Incomplete fields are discarded (not partially extracted)
- Focus on extracting **complete key-value pairs** only

### ViaQ Envelope Extension

**Scenario: Audit log truncation example**

**Without truncation (current behavior—message dropped entirely):**
```
No log record at all. The oversized audit event is silently discarded.
Downstream systems never see the event, making compliance auditing and forensics impossible.
```

**With truncation and fuzzy JSON parsing (proposed behavior):**

Original oversized audit log (2.5MB, exceeds 2MB limit):
```json
{
  "apiVersion": "audit.k8s.io/v1",
  "kind": "Event",
  "level": "RequestResponse",
  "verb": "create",
  "user": {"username": "admin@example.com", "groups": ["system:masters"]},
  "sourceIPs": ["10.0.0.5"],
  "userAgent": "kubectl/v1.29.0",
  "objectRef": {
    "apiVersion": "v1",
    "kind": "Pod",
    "namespace": "production",
    "name": "my-web-app-789abc",
    "uid": "d1234567-89ab-cdef-0123-456789abcdef",
    "resourceVersion": "12345678"
  },
  "requestObject": {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "my-web-app-789abc", ...}, "spec": {"containers": [{"name": "web", "image": "myimage:v1.2.3", "resources": {"limits": {"cpu": "500m", "memory": "512Mi"}, "requests": {"cpu": "250m", "memory": "256Mi"}}, "volumeMounts": [...500 more lines of YAML spec...]}}},
  "responseStatus": {"code": 201, "message": ""},
  "requestURI": "/api/v1/namespaces/production/pods",
  "auditID": "d1234567-89ab-cdef-0123-456789abcdef",
  "@timestamp": "2026-09-22T10:00:00Z"
}
```

Truncated output (after fuzzy JSON parsing extracts key audit fields):
```json
{
  "message": "{\"apiVersion\":\"audit.k8s.io/v1\",\"kind\":\"Event\",\"level\":\"RequestResponse\",\"verb\":\"create\",\"user\":{\"username\":\"admin@example.com\",\"groups\":[\"system:masters\"]},\"sourceIPs\":[\"10.0.0.5\"],\"userAgent\":\"kubectl/v1.29.0\",\"objectRef\":{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"namespace\":\"production\",\"name\":\"my-web-app-789abc\",\"uid\":\"d1234567-89ab-cdef-0123-456789abcdef\",\"resourceVersion\":..TRUNCATED",
  "verb": "create",
  "user": {"username": "admin@example.com", "groups": ["system:masters"]},
  "sourceIPs": ["10.0.0.5"],
  "userAgent": "kubectl/v1.29.0",
  "objectRef": {
    "apiVersion": "v1",
    "kind": "Pod",
    "namespace": "production",
    "name": "my-web-app-789abc",
    "uid": "d1234567-89ab-cdef-0123-456789abcdef",
    "resourceVersion": "12345678"
  },
  "responseStatus": {"code": 201},
  "requestURI": "/api/v1/namespaces/production/pods",
  "auditID": "d1234567-89ab-cdef-0123-456789abcdef",
  "structured_partial": true,
  "hostname": "node-1.example.com",
  "@timestamp": "2026-09-22T10:00:00Z"
}
```

**Key differences:**
- **Without truncation:** Event is lost entirely. No who, what, when, where information is captured. Compliance audit trails are incomplete.
- **With truncation:** Key audit fields (`verb`, `user`, `objectRef`, `responseStatus`, `auditID`) are preserved even though the full resource spec is truncated. Downstream systems can still identify who performed what action on which resource and when, even if some details are missing. The `structured_partial: true` flag alerts consumers that this is incomplete data.

Note: Parsed fields are merged into root, not nested in a `structured` object. This matches existing audit log parsing behavior.

## Scope of Change

### Repos Affected

| Repo | Changes |
|---|---|
| **vector** (fork) | • Add fuzzy JSON parser transform (`audit_json_fuzzy_parser.rs`)<br>• Add metrics: `message_truncated_total`, `audit_json_fuzzy_parse_attempts_total`, `audit_json_fuzzy_parse_success_total`<br>• Tests for transform scenarios |
| **cluster-logging-operator** | • Extend CLF API: add `tuning.maxMergedLineBytes` to input specs<br>• Update Vector config generation: map CLF field to Vector config, hardcode `max_merged_line_action: truncate`<br>• Different defaults per input type (app/infra/audit defaults TBD)<br>• Set `max_line_bytes` = `max_merged_line_bytes` to allow partial events through |
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
          maxMergedLineBytes: "512KB"      # override default (default TBD)
    
    - name: my-audit
      type: audit
      audit:
        tuning:
          maxMergedLineBytes: "2MB"        # override default (default TBD)
```

**Backward compatibility:**
- Field is optional; existing CRs work without changes
- Omitting field uses defaults (values TBD based on real-world data analysis)
- Default behavior changes from silent drop to truncate (behavioral change, but preserves more data and improves observability)

## Migration Phases

### Phase 1: Vector Fuzzy JSON Parser Transform (Red Hat fork)

**Implementation approach:** Two options exist—VRL (fast to implement) vs Rust (better performance). Start with VRL proof-of-concept to validate feasibility.

#### Phase 1a: VRL Proof-of-Concept (1-3 days)
1. Implement fuzzy parser using Vector Remap Language (VRL)
   - VRL transform that detects `..TRUNCATED` suffix in audit logs
   - Parse JSON from truncated message, extract priority fields
   - Merge extracted fields to root level, add `structured_partial: true`
2. Test with real Kubernetes audit logs truncated at various offsets
   - Mid-key: `{"verb": "cre`
   - Mid-value: `{"verb": "create", "user": {"usern`
   - Mid-nested-object: `{"verb": "create", "user": {"username": "admin", "groups": [`
3. Measure success rate: % of truncated logs that extract ≥1 field
4. Benchmark latency: p99 parse time for 512KB, 1MB, 2MB audit log payloads
5. Document edge cases and limitations

**Decision criteria after PoC:**
- ✅ **Ship VRL** if: success rate >80% AND p99 latency <10ms
- ⚠️ **Migrate to Rust** if: success rate >80% BUT p99 latency >10ms (VRL too slow)
- ❌ **Reconsider approach** if: success rate <80% (fuzzy parsing unreliable)

#### Phase 1b: Rust Implementation (if needed based on PoC results)
1. Implement `audit_json_fuzzy_parser.rs` transform in Vector fork
   - Use `serde_json::StreamDeserializer` for incremental parsing
   - Extract priority fields as they're encountered
   - Handle edge cases: mid-key truncation, incomplete nested objects, broken arrays
2. Add unit tests for partial JSON extraction scenarios
3. Register transform in Vector's transform registry
4. Add metrics to Vector's internal events system:
   - `audit_json_fuzzy_parse_attempts_total` (counter, labeled by hostname)
   - `audit_json_fuzzy_parse_success_total` (counter, labeled by hostname)
5. Benchmark to confirm <5ms p99 latency
6. This stays in RH fork; not proposed upstream

**Metrics exposure (both VRL and Rust):**
- VRL: Increment counters via VRL `counter_increment()` function in transform
- Rust: Emit events via Vector's internal events system, exposed at `/metrics` endpoint

### Phase 2: CLF API Extension
1. Add `tuning.maxMergedLineBytes` field to CLF API
2. Update CRD schema and validation
3. Generate API documentation
4. Add unit tests for API validation

### Phase 3: CLO Reconciler Updates
1. Map CLF `tuning.maxMergedLineBytes` to Vector config
2. Hardcode `max_merged_line_action: truncate` in generated Vector config
3. Set `max_line_bytes` = `max_merged_line_bytes` to allow partial events through
4. Add different defaults per input type (values TBD based on data analysis)
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
| Audit logs missing critical fields after truncation | Users can increase `maxMergedLineBytes` for audit; defaults chosen to accommodate typical events |
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
- Fuzzy parser latency: benchmark with 512KB, 1MB, 2MB JSON payloads
- Truncation throughput: sustained rate of oversized logs, measure CPU/memory
- No regression: logs within limits have no performance change

## Open Questions

1. **Target release** — Which OpenShift Logging version? (6.7, 6.8?)
2. **Validation warning for high limits** — Should CLO warn when `maxMergedLineBytes > 64MB` (approaching 128MB Vector limit)?
3. **Default `maxMergedLineBytes` values** — What should the defaults be for different log types?
   - **Vector upstream**: `max_merged_line_bytes` has no default (optional field)
   - **Vector file-level default**: `max_line_bytes = 32KB` (but this is for individual lines, not merged)
   - **Needs analysis**: Real-world merged log sizes in OpenShift clusters (app, infra, audit)
   - **Action**: Analyze customer data before deciding on defaults
4. **Fuzzy parser implementation approach** — VRL (fast to implement) vs Rust (better performance)?
   - **Decision point**: After Phase 1a VRL proof-of-concept completes
   - **Timeline**: VRL PoC should complete within 1-3 days of starting implementation
   - **Criteria**: Success rate >80% AND latency <10ms → ship VRL; otherwise migrate to Rust or reconsider approach
   - **Fallback**: If fuzzy parsing proves unreliable (<80% success), consider simpler alternatives (regex-based field extraction, top-level fields only)

### Resolved

- **Vector upstream acceptance** — Fuzzy JSON parser stays in RH fork, not proposed upstream.
- **Fuzzy parser configurability** — Always-on for audit logs when truncation occurs. No user toggle.
- **oversizedAction configuration** — Removed. Truncation is always enabled; no drop option exposed.
- **LOG-9459 relationship** — LOG-9459 is complete via upstream Vector PR #25567 cherry-pick. This spec builds on that foundation.

## Future Enhancements (Out of Scope)

- **File-level truncation** — Vector doesn't support truncating individual lines at the file reader level (only drop). Upstream feature request.
- **Custom truncation marker** — `..TRUNCATED` is hardcoded by Vector. Could be configurable in future.
- **Smart JSON truncation** — Attempt to close JSON structure gracefully (add `}` or `]`) instead of leaving it broken. Complex edge cases.
- **CLF-level fuzzy parser field configuration** — Expose the priority fields list through the ClusterLogForwarder CR so users don't need to edit Vector config directly.
- **Truncation for non-Kubernetes logs** — Currently only applies to merged partial events from Kubernetes container logs. Could extend to journal logs, receiver inputs, etc.
