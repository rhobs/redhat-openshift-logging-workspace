# LOG-9876: Drop Historical Logs by Event Timestamp

## Problem

When a ClusterLogForwarder is first deployed (or collectors start with no checkpoints), Vector can read a large existing backlog. Users need to discard records predating a known incident, migration, or collection boundary across all supported log types.

Current workarounds are operational:

- Point CLF at credentials that fail until the backlog is drained, then swap to real credentials.
- Rely on Loki rate limits and hope ingestion is not disrupted.

## Decision

Extend the existing `drop` filter with an `olderThan` cutoff. The collector generates VRL that compares each normalized record's `@timestamp` to the configured cutoff and drops the record only when the timestamp is valid and strictly earlier.

`olderThan` accepts an ISO 8601 timestamp with an explicit offset or a date-only `YYYY-MM-DD` value. The operator normalizes date-only input to midnight UTC before generating Vector configuration. Missing or unparseable event timestamps are retained.

## Alternatives Considered

### Use `ignore_older_secs` for file-backed sources — rejected

`ignore_older_secs` tests a file's last-modified time, not the age of records in the file. A long-running pod or service can contain hours or days of history while its most recent write keeps the file current. It also cannot apply to journald. It cannot meet this Jira's record-timestamp requirement.

### Add a separate timestamp-filter type — rejected

A separate type would duplicate the existing drop-filter attachment, ordering, validation, and pipeline semantics. `olderThan` is another predicate for dropping a record, so it belongs on an existing drop item.

## Design

### API

Add optional `olderThan` to each existing `drop` item and make `test` optional:

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
spec:
  serviceAccount:
    name: collector-sa
  filters:
    - name: discard-historical
      type: drop
      drop:
        - olderThan: "2026-09-16"
    - name: discard-temporary-history
      type: drop
      drop:
        - test:
            - field: .kubernetes.namespace_name
              matches: "temporary"
          olderThan: "2026-09-16T12:00:00-04:00"
  pipelines:
    - name: forward
      filterRefs: [discard-historical]
      inputRefs: [application, infrastructure, audit]
      outputRefs: [my-store]
```

- Each drop item must define `test`, `olderThan`, or both. An item with neither is invalid.
- Conditions in `test` and `olderThan` are ANDed within an item. Items remain ORed, preserving existing drop-filter behavior.
- `test` remains required only when field-based conditions are configured; its individual conditions retain the existing `field` plus exactly one of `matches` or `notMatches` requirements.

### Vector Config Generation

The existing drop-filter transform gains a VRL timestamp predicate. It runs after source-specific normalization, so `@timestamp` is the canonical event timestamp for application, infrastructure container, infrastructure journal, and audit inputs. For a timestamp predicate, VRL parses `@timestamp`; a parse failure leaves the record untouched. A parseable value before the normalized cutoff causes the transform to drop the record.

The transform is generated only for pipelines that reference the filter. It does not alter source configuration, checkpoint handling, file discovery, or journald invocation. Therefore, Vector still reads and decodes the backlog before it can be filtered, and the cutoff applies to records encountered after any restart.

### Implementation Files

| File | Change |
|---|---|
| `api/observability/v1/filter_types.go` | Add `olderThan` to `DropTest`, make `test` optional, and validate permitted combinations and timestamp syntax. |
| `internal/validations/observability/filters/validate_filters.go` | Validate `olderThan` and reject a drop item with neither predicate. |
| `internal/generator/vector/filter/drop/filter.go` | Generate timestamp-comparison VRL alongside existing field predicates. |

### Testing

**Unit tests** (API validation and VRL generation):

- Accept a full ISO 8601 timestamp with an explicit offset and a date-only UTC-normalized value.
- Reject malformed cutoffs and a drop item containing neither `test` nor `olderThan`.
- Preserve existing field-only drop filters unchanged.
- Verify valid older timestamps drop; equal and newer timestamps remain; missing and malformed event timestamps remain.
- Verify a combined item requires both its field conditions and cutoff, while separate items retain OR behavior.

**Functional and E2E tests** (`cluster-logging-operator` and `openshift-logging-e2e-tests`):

- Verify timestamp-based filtering for application, infrastructure container, infrastructure journal, and audit inputs.
- Restart the collector and verify the filter applies to subsequently read records, including records retained by checkpoints.

### Documentation

- Update `openshift-docs` to document `spec.filters[].drop[].olderThan`.
- Update `.ai/spec/what/log-forwarding.md` and `.ai/spec/what/log-collection.md` with the filter contract and source coverage.
