# Vector to OpenTelemetry Collector Migration

## Summary

Migrate Red Hat OpenShift Logging from Vector to OpenTelemetry Collector as the log collection backend. CLO keeps the ClusterLogForwarder CRD and translates it into OpenTelemetryCollector CRs, which the OTEL Operator reconciles. This reuses the existing OTEL product infrastructure (operator, collector image, build pipeline) and provides users a gradual migration path with no breaking CRD changes.

## Phased Migration

### Phase 1 — Collector Choice (Technology Preview)

Add `spec.collector.type: Vector | OTELCollector` to ClusterLogForwarder. When `OTELCollector` is selected, CLO generates an `OpenTelemetryCollector` CR instead of a Vector DaemonSet. The OTEL Operator reconciles it. Requires the TP annotation on the CLF. Both collectors produce identical output for the same CLF configuration. The OTEL Operator must be installed on the cluster as a prerequisite.

### Phase 2 — OTEL Collector Default (GA)

`OTELCollector` becomes the default value for `spec.collector.type`. Vector is deprecated (bug fixes only). Users who explicitly set `Vector` continue to work. The TP annotation is no longer required.

### Phase 3 — Consolidation (Open)

Options remain open. One possibility: the OTEL Operator adopts the ClusterLogForwarder CRD directly (same API group, same version, same spec), and CLO is retired. Users see no CRD change. Another possibility: a higher-level abstraction emerges. This phase is deliberately not designed now — Phase 1 and 2 inform it.

## Architecture — Operator Cooperation

### Ownership Model

CLO owns the ClusterLogForwarder CR. When `spec.collector.type: OTELCollector`, CLO creates/updates/deletes an `OpenTelemetryCollector` CR in the same namespace. The OTEL Operator watches `OpenTelemetryCollector` CRs as it normally does — it has no knowledge that CLO created it. CLO treats the generated `OpenTelemetryCollector` CR as a child resource (sets owner references, garbage-collects on CLF deletion).

### Generated CR Naming

The `OpenTelemetryCollector` CR is named `<clf-name>-logging` (e.g., `instance-logging`) to avoid collisions with user-created OTEL collectors.

### Lifecycle Flow

```
User creates/updates CLF (type: OTELCollector)
  -> CLO validates CLF spec
  -> CLO translates CLF into OTEL Collector pipeline config
  -> CLO creates/updates OpenTelemetryCollector CR
  -> OTEL Operator reconciles -> deploys collector DaemonSet/Deployment
  -> CLO watches the OpenTelemetryCollector CR status
  -> CLO reflects collector health back into CLF status conditions
```

### Mode Mapping

- CLF with node-level inputs (application, infrastructure, audit) -> `OpenTelemetryCollector` with `mode: daemonset`
- CLF with receiver-only inputs -> `OpenTelemetryCollector` with `mode: deployment`

### Resource Passthrough

CLF's `spec.collector.resources`, `nodeSelector`, `tolerations`, `affinity` are mapped directly to the corresponding fields on the `OpenTelemetryCollector` CR spec.

### Prerequisites

CLO checks that the OTEL Operator is installed (CRD exists) when `OTELCollector` is selected. If not, CLO sets a degraded status condition on the CLF with a clear message.

### RBAC

CLO needs RBAC permissions to create/update/delete/watch `OpenTelemetryCollector` CRs. The OTEL Operator's auto-RBAC creation handles the collector's own permissions (e.g., reading pod logs via filelog receiver).

## Config Translation — CLF to OTEL Collector Pipeline

### Input Mapping

| CLF Input | OTEL Collector Receiver | Notes |
|---|---|---|
| `application` | `filelog` receiver with include paths for `/var/log/pods/` excluding infra namespaces | Namespace include/exclude filters become filelog `include`/`exclude` path patterns |
| `infrastructure` (container) | `filelog` receiver with include paths for infra namespace pods | `default`, `kube-*`, `openshift-*` |
| `infrastructure` (node) | `journald` receiver | Currently TP in OTEL distro — needs GA promotion |
| `audit` (kubeAPI, openshiftAPI) | `filelog` receiver reading `/var/log/kube-apiserver/`, `/var/log/openshift-apiserver/` | JSON-structured audit log files |
| `audit` (auditd) | `filelog` receiver reading `/var/log/audit/audit.log` | |
| `audit` (ovn) | `filelog` receiver reading `/var/log/ovn/` | |
| `receiver` (HTTP) | `otlp` receiver or custom HTTP receiver | Depends on expected input format (`kubeAPIAudit`) |
| `receiver` (syslog) | `syslog` receiver | Not currently in OTEL distro — needs to be added |

### Filter Mapping

| CLF Filter | OTEL Collector Processor | Notes |
|---|---|---|
| `drop` | `filter` processor | OTTL conditions to match and drop records |
| `prune` | `transform` processor | OTTL statements to delete/keep fields |
| `kubeAPIAudit` | `filter` processor | OTTL conditions on audit level/verb/resource |
| `openshiftLabels` | `transform` processor | OTTL `set` statements to add attributes |
| `parse` (JSON) | `transform` processor | OTTL JSON parsing on body |
| `detectMultilineException` | `multiline` config on filelog receiver | Filelog's `multiline` operator handles this at ingestion time; preferred over a custom processor because it avoids splitting and re-joining |

### Output Mapping

| CLF Output | OTEL Collector Exporter | Distro Status |
|---|---|---|
| `lokiStack` | `otlphttp` exporter | GA — LokiStack already supports OTLP ingestion |
| `otlp` | `otlp` / `otlphttp` exporter | GA |
| `kafka` | `kafka` exporter | GA |
| `cloudwatch` | `awscloudwatchlogs` exporter | TP — needs GA promotion |
| `googleCloudLogging` | `googlecloud` exporter | TP — needs GA promotion |
| `elasticsearch` | `elasticsearch` exporter | Not in distro — needs to be added from contrib |
| `splunk` | `splunk_hec` exporter | Not in distro — needs to be added from contrib |
| `http` | `otlphttp` exporter or generic HTTP exporter | May need custom config |
| `syslog` | `syslog` exporter | Not in distro — needs to be added from contrib |
| `s3` | `awss3` exporter | Not in distro — needs to be added from contrib |
| `loki` | `loki` exporter | Not in distro — needs to be added from contrib |
| `azureLogsIngestion` | Azure exporter | Not in contrib — needs investigation |

Output gaps will be investigated separately.

### Kubernetes Metadata Enrichment

The `k8sattributes` processor (GA) is always injected into the pipeline to enrich logs with pod name, namespace, labels, node name — equivalent to what Vector provides via its `kubernetes_logs` source.

### Pipeline Wiring

CLF pipelines (inputRefs -> filterRefs -> outputRefs) are translated into OTEL Collector `service.pipelines` entries. Each CLF pipeline becomes one or more OTEL Collector `logs/` pipelines. The `routing` connector (TP, needs GA promotion) may be needed to fan out to multiple exporters with different configs.

### Templating

CLF's `{.field.path||"fallback"}` template expressions are translated into OTTL (OpenTelemetry Transformation Language) expressions within `transform` or `routing` processors. Full backward compatibility with Vector's templating behavior is required.

## Data Model Compatibility

### Dual Data Model Support

The CLF's existing `dataModel` field controls the output format regardless of which collector backend is used.

### ViaQ Data Model with OTEL Collector

When `dataModel: Viaq` (the default), CLO injects `transform` processors into the generated OTEL Collector pipeline that reshape the OTEL-native log records into ViaQ schema:

- OTEL resource/log attributes are mapped to ViaQ's flat field structure (e.g., `k8s.namespace.name` -> `.kubernetes.namespace_name`)
- Timestamp handling matches ViaQ conventions (`@timestamp`, `viaq_msg_id`)
- The `message` field is populated from the OTEL log body
- Log type metadata (`log_type: application|infrastructure|audit`) is set as in Vector today

This transformation happens inside the collector pipeline before export, so all downstream destinations see ViaQ-formatted data identical to what Vector produces today.

### OTEL Data Model with OTEL Collector

When `dataModel: Otel`, no reshaping is applied — the collector's native OTEL log records flow through as-is.

### ViaQ Maintenance Escape Hatch

If the transform processors needed to produce ViaQ from OTEL Collector become a maintenance burden, ViaQ support in the OTEL Collector path can be dropped. Users on the OTEL Collector path would use the OTEL data model only.

### Conformance Testing

Before Phase 1 ships, a conformance test suite compares ViaQ output field-by-field from both collectors given identical input logs for all three input types (application, infrastructure, audit).

## OTEL Collector Distro Changes

### Components to Add (from upstream contrib)

Exporters:
- `elasticsearch` exporter
- `splunk_hec` exporter
- `syslog` exporter
- `awss3` exporter
- `loki` exporter
- Azure exporter (needs investigation)

Receivers:
- `syslog` receiver (for CLF receiver inputs)

### Components to Promote from TP to GA

- `journald` receiver — infrastructure node journal collection
- `awscloudwatchlogs` exporter — CloudWatch output
- `googlecloud` exporter — Google Cloud Logging output
- `routing` connector — multi-output pipeline fan-out

### Components Already GA and Ready

- `filelog` receiver — log file collection
- `k8sattributes` processor — Kubernetes metadata enrichment
- `filter` processor — drop/audit filtering
- `transform` processor — field manipulation, ViaQ reshaping, templating
- `batch` processor — batching before export
- `memory_limiter` processor — back-pressure
- `otlp`/`otlphttp` exporters — LokiStack and OTLP outputs
- `kafka` exporter — Kafka output

### Shared Collector Image

All new components are added to the shared `manifest.yaml` in `redhat-opentelemetry-collector`. One collector image serves both the OTEL product and logging use cases. Each addition goes through the OTEL product's component acceptance process (upstream stability level, security review, documentation).

## CLO Code Changes

### New CRD Field

Add `type` field to `spec.collector` on ClusterLogForwarder with values `Vector` (default) and `OTELCollector`. When `OTELCollector` is set, requires the TP annotation (Phase 1 only).

### New Config Generator

A new `internal/generator/otel/` package mirrors the structure of `internal/generator/vector/`:
- `input/` — translates CLF inputs to filelog/journald receiver configs
- `output/` — translates CLF outputs to OTEL exporter configs
- `filter/` — translates CLF filters to OTEL processor configs
- `pipeline/` — wires receivers -> processors -> exporters into `service.pipelines`
- `datamodel/` — injects ViaQ transform processors when `dataModel: Viaq`

### New Reconciliation Path

The existing controller in `internal/controller/observability/` gains a branch: when `spec.collector.type == OTELCollector`, instead of creating a Vector DaemonSet, it assembles the OTEL Collector config, constructs an `OpenTelemetryCollector` CR, and creates/updates it via the Kubernetes API. The controller watches the `OpenTelemetryCollector` CR's status and reflects it into the CLF's status conditions.

### Validation

The existing validation logic in `internal/validations/` is extended to check OTEL-specific constraints (e.g., OTEL Operator CRD must exist).

### No Changes to the Vector Path

The Vector config generator, Vector deployment logic, and all existing tests remain untouched. The two paths are completely independent — selected by the `type` field.

### Testing Strategy

- Unit tests for each config generator module (input/output/filter/pipeline mapping)
- Integration tests that create a CLF with `OTELCollector` type and verify the generated `OpenTelemetryCollector` CR matches expected config
- E2E tests that deploy both collectors with identical CLF configs and compare output at each destination
- Conformance test suite for ViaQ data model field-by-field comparison

## Migration Path and User Experience

### Phase 1 User Experience

1. User installs both CLO and OTEL Operator (OTEL Operator may already be present for tracing/metrics)
2. User adds the TP annotation to their CLF
3. User sets `spec.collector.type: OTELCollector`
4. CLO validates, generates the `OpenTelemetryCollector` CR, OTEL Operator deploys the collector
5. User can switch back to `Vector` at any time — CLO deletes the `OpenTelemetryCollector` CR and creates the Vector DaemonSet

### Side-by-Side Comparison

Users can run two CLF instances — one with Vector, one with OTEL Collector — in different namespaces, both forwarding to the same destinations, to validate output compatibility before committing to the switch.

### Status Reporting

CLF status conditions report the collector backend in use and surface issues from the `OpenTelemetryCollector` CR's status:
- `CollectorType: OTELCollector`
- `CollectorReady: True/False` (reflects OTEL Operator's reconciliation status)
- `OTELOperatorAvailable: True/False`

### Phase 2 Migration

When OTEL Collector becomes default, existing CLFs without an explicit `spec.collector.type` switch automatically. Users who need Vector set `spec.collector.type: Vector` explicitly. A deprecation warning is surfaced in CLF status conditions.

### Documentation

The migration guide covers:
- Prerequisites (OTEL Operator installation)
- How to enable OTEL Collector backend
- Known behavioral differences (if any)
- How to roll back to Vector
- Output-specific considerations
