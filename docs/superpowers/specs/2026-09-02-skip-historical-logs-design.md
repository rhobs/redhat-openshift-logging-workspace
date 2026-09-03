# LOG-9876: Skip Historical Logs on First-Time Collection

## Problem

When a ClusterLogForwarder is first deployed (or collectors start with no checkpoints), Vector reads existing sources from the beginning. On long-running clusters this causes a large historical backlog to be shipped as fast as the collector can send it, overwhelming downstream systems.

Current workarounds are operational:
- Point CLF at credentials that fail until the backlog is drained, then swap to real credentials
- Rely on Loki rate limits and hope ingestion is not disrupted

## Design

### API

Add a `readFrom` field to the collector spec:

```go
// ReadFromMode controls where the collector starts reading when no checkpoint exists.
// +kubebuilder:validation:Enum=Beginning;End
type ReadFromMode string

const (
    ReadFromModeBeginning ReadFromMode = "Beginning"
    ReadFromModeEnd       ReadFromMode = "End"
)
```

Usage:

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
spec:
  collector:
    readFrom: End
  serviceAccount:
    name: collector-sa
  pipelines:
    - name: forward
      inputRefs: [application, infrastructure, audit]
      outputRefs: [my-store]
```

- `Beginning` (default, current behavior): read from the start of all sources when no checkpoint exists.
- `End`: skip historical data. When no checkpoint exists, start from "now" for all input types.
- When a checkpoint exists (normal restart), it always takes priority regardless of this setting. This is Vector's built-in behavior.

### Vector Config Generation

When `spec.collector.readFrom: End`, the CLO generates these additional fields per source type:

| Input Type | Vector Source | Field Added |
|---|---|---|
| Application containers | `kubernetes_logs` | `read_from = "end"` |
| Infrastructure containers | `kubernetes_logs` | `read_from = "end"` |
| Infrastructure journal | `journald` | `since_now = true` |
| Audit (auditd, kubeAPI, openshiftAPI, ovn) | `file` | `read_from = "end"` |

When `readFrom` is omitted or `Beginning`, no additional fields are generated.

**Interaction with `ignore_older_secs` on audit sources:** The existing `ignore_older_secs` (default 3600) on audit file sources is retained. It is a file-staleness check based on modification time, complementary to `read_from`. With `read_from: end`, `ignore_older_secs` becomes redundant for the positioning purpose but remains useful for its original role (LOG-9359: preventing re-read of inactive audit files).

**Journald mechanism:** The journald source does not support `read_from`. Instead, `since_now: true` tells Vector to pass `--since=now` to the `journalctl` subprocess, achieving the same effect. When a checkpoint cursor exists, it takes priority.

### No Vector Changes Required

All three Vector source types already support the needed configuration:
- `kubernetes_logs`: `read_from` field (default `beginning`)
- `file`: `read_from` field (default `beginning`)
- `journald`: `since_now` field (default `false`)

### Implementation Files

| File | Change |
|---|---|
| `api/observability/v1/clusterlogforwarder_types.go` or collector types file | Add `ReadFrom ReadFromMode` field to collector spec, `ReadFromMode` type and constants |
| `internal/generator/vector/api/sources/kubernetes_log_source.go` | Add `ReadFrom` field to `KubernetesLogs` struct |
| `internal/generator/vector/api/sources/file_source.go` | Add `ReadFrom` field to `File` struct |
| `internal/generator/vector/api/sources/journald_source.go` | Add `SinceNow` field to `Journald` struct |
| `internal/generator/vector/input/container.go` | Pass `readFrom` setting to `KubernetesLogs` source |
| `internal/generator/vector/input/audit.go` | Pass `readFrom` setting to `File` sources |
| `internal/generator/vector/input/journal.go` | Pass `readFrom` setting as `SinceNow` to `Journald` source |

### Testing

**Unit tests** (config generation):
- For each source type, add a fixture with `readFrom: End` and verify the generated TOML contains the appropriate field.
- Verify default: when `readFrom` is omitted, no `read_from`/`since_now` fields appear.
- Follow existing pattern in `internal/generator/vector/input/source_test.go`.

**E2E tests** (`openshift-logging-e2e-tests`):
- Deploy CLF with `readFrom: End` on a cluster with existing logs.
- Verify collector only forwards logs written after deployment.
- Restart collector, verify checkpoint-based resume (no gap).

### Documentation

- Update `openshift-docs` to document `spec.collector.readFrom`.
- Update `.ai/spec/what/log-collection.md` with new behavioral rule and configuration surface entry.

## Future Work

- Per-input `readFrom` override (if the global setting proves insufficient).
- `ignore_older_secs` support for journald source in Vector (separate ticket if needed).
