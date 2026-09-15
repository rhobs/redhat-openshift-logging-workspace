# LOG-9876: Skip Historical Logs on First-Time Collection

## Problem

When a ClusterLogForwarder is first deployed (or collectors start with no checkpoints), Vector reads existing sources from the beginning. On long-running clusters this causes a large historical backlog to be shipped as fast as the collector can send it, overwhelming downstream systems.

Current workarounds are operational:
- Point CLF at credentials that fail until the backlog is drained, then swap to real credentials
- Rely on Loki rate limits and hope ingestion is not disrupted

## Decision

Add `spec.collector.readFrom` with `Beginning` (the default) and `End` values. `End` is the solution for LOG-9876: when a source has no checkpoint, it begins at the end of a file or at the current journal position. This prevents the collector from reading, processing, and forwarding the historical backlog. Existing checkpoints always take precedence, so ordinary collector restarts resume normally.

This is intentionally a source-positioning control, not a time-based retention policy. A user who wants to suppress events older than a duration has different semantics and operational trade-offs; that is deferred as separate future work.

## Alternatives Considered

### Use `ignore_older_secs` for file-backed sources — rejected

`ignore_older_secs` tests a file's last-modified time, not the age of records in the file. A long-running pod or service can have a log file containing hours or days of history while its most recent write keeps the file's modification time current. With `ignore_older_secs: 600`, Vector will still open that file and, under its default start position, read the entire backlog. The option is useful for avoiding inactive or rotated files, and the existing audit use remains unchanged, but it cannot meet this JIRA's requirement.

### Use a VRL timestamp filter — viable future feature, not this solution

A generated VRL transform can drop an event whose timestamp is older than a configured duration, including for journald. That offers fine-grained, per-input event-age control without changing Vector source code. It does not prevent the source from reading and decoding historical records first, so it cannot protect collector startup I/O or CPU. It also applies after every restart, including after a checkpoint: records that accumulated while the collector was unavailable can be dropped once they exceed the duration. Timestamp-missing and clock-skewed records require an explicit policy.

If this capability is added later, it must have a distinct name such as `dropOlderThan`; it must not reuse `ignoreOlder`, whose established meaning is file staleness.

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

**Interaction with `ignore_older_secs` on audit sources:** The existing `ignore_older_secs` (default 3600) on audit file sources is retained. It is a file-staleness check based on modification time, complementary to `read_from`, and remains useful for its original role (LOG-9359: preventing re-read of inactive audit files).

**Journald mechanism:** The journald source does not support `read_from`. Instead, `since_now: true` tells Vector to pass `--since=now` to the `journalctl` subprocess, achieving the same effect. When a checkpoint cursor exists, it takes priority.

### Required Vector Change

The Vector file server must honor an explicit `read_from = "end"` for files discovered after startup. This is required for `kubernetes_logs`, whose files are normally discovered asynchronously after the Kubernetes reflector has populated its metadata. Without the change, those files fall back to reading from the beginning and `readFrom: End` does not prevent their backlog from being read.

The Vector change must preserve two existing guarantees:

- A stored checkpoint takes precedence over `read_from`, so restarts resume normally.
- The default `read_from = "beginning"` behavior continues to read files discovered after startup from their beginning.

No Vector change is required for journald: its existing `since_now` option already invokes `journalctl --since=now` when no checkpoint cursor exists.

### Implementation Files

| File | Change |
|---|---|
| `vector/lib/file-source/src/file_server.rs` | Honor explicit `read_from = "end"` for files discovered after startup while retaining checkpoint priority |
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

**Vector tests** (source behavior):
- Verify an explicitly configured `read_from = "end"` starts a file discovered after startup at its end.
- Verify a stored checkpoint still overrides `read_from = "end"`.
- Verify the default beginning behavior for files discovered after startup is unchanged.

**E2E tests** (`openshift-logging-e2e-tests`):
- Deploy CLF with `readFrom: End` on a cluster with existing logs.
- Verify collector only forwards logs written after deployment.
- Restart collector, verify checkpoint-based resume (no gap).

### Documentation

- Update `openshift-docs` to document `spec.collector.readFrom`.
- Update `.ai/spec/what/log-collection.md` with new behavioral rule and configuration surface entry.

## Future Work

- A separately named per-input event-age policy (for example, `dropOlderThan`) using a VRL timestamp filter, with explicit timestamp-missing and restart semantics.
- Per-input `readFrom` override, if the global setting proves insufficient.
