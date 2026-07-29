# Repo Map

Maps product concerns to the repositories and files that own them. Use this to quickly find where to look or make changes.

## Concern → Repo Mapping

| Concern | Primary Repo | Key Paths |
|---|---|---|
| ClusterLogForwarder API | `cluster-logging-operator/` | `api/observability/v1/` |
| LogFileMetricExporter API | `cluster-logging-operator/` | `api/logging/v1alpha1/` |
| Log collection logic | `cluster-logging-operator/` | `internal/controller/observability/` |
| Vector config generation | `cluster-logging-operator/` | `internal/generator/vector/` |
| Adding a new output type | `cluster-logging-operator/` | `api/observability/v1/output_types.go`, `internal/generator/vector/output/<type>/` |
| Adding a new filter type | `cluster-logging-operator/` | `api/observability/v1/filter_types.go`, `internal/generator/vector/filter/` |
| Adding a new input type | `cluster-logging-operator/` | `api/observability/v1/input_types.go`, `internal/generator/vector/input/` |
| Collector deployment (DaemonSet/Deployment) | `cluster-logging-operator/` | `internal/collector/` |
| Validation of CLF spec | `cluster-logging-operator/` | `internal/validations/` |
| Data model (ViaQ/OTEL) | `cluster-logging-operator/` | `internal/datamodels/` |
| TLS profile handling | `cluster-logging-operator/` | `internal/tls/`, `internal/controller/tlsprofile/` |
| CLO metrics and dashboards | `cluster-logging-operator/` | `internal/metrics/` |
| CLO must-gather | `cluster-logging-operator/` | `must-gather/` |
| LokiStack API | `loki/` | `operator/api/loki/v1/` |
| AlertingRule / RecordingRule / RulerConfig APIs | `loki/` | `operator/api/loki/v1/` |
| LokiStack operator logic | `loki/` | `operator/internal/` |
| OpenShift-specific Loki features | `loki/` | `operator/internal/manifests/openshift/` |
| Loki storage backend config | `loki/` | `operator/internal/manifests/storage/` |
| Loki OTLP config | `loki/` | `operator/internal/manifests/openshift/otlp/` |
| Vector collector internals | `vector/` | `src/sources/`, `src/transforms/`, `src/sinks/` |
| Vector configuration model | `vector/` | `src/config/`, `lib/vector-config/` |
| Logging UI plugin frontend | `logging-view-plugin/` | `web/src/` |
| Logging UI plugin backend | `logging-view-plugin/` | `cmd/`, `pkg/server/` |
| UI log table component | `logging-view-plugin/` | `web/src/components/logs-table.tsx` |
| UI LogQL query input | `logging-view-plugin/` | `web/src/components/logs-query-input.tsx` |
| UI schema selector (otel/viaq) | `logging-view-plugin/` | `web/src/components/schema-dropdown.tsx` |
| UI alert integration | `logging-view-plugin/` | `web/src/components/alerts/` |
| Product documentation | `openshift-docs/` | `modules/`, `assemblies/` |
| Feature support status (GA/TP) | `openshift-docs/` | grep for "Technology Preview" in `modules/` |
| Data model documentation | External | `github.com/rhobs/observability-data-model` |

## Cross-Repo Change Patterns

| Change Type | Repos Involved |
|---|---|
| New output type | `cluster-logging-operator/` (API + generator), `openshift-docs/` (documentation) |
| New filter type | `cluster-logging-operator/` (API + generator), `openshift-docs/` (documentation) |
| New LokiStack feature | `loki/` (operator), `openshift-docs/` (documentation) |
| New UI feature | `logging-view-plugin/` (frontend), `openshift-docs/` (documentation) |
| Promoting TP → GA | `cluster-logging-operator/` or `loki/` (remove TP gates), `openshift-docs/` (update support status) |
| Data model change | `cluster-logging-operator/` (data model), `logging-view-plugin/` (UI parsing), `openshift-docs/` (docs) |
| Vector upstream update | `vector/` (upstream), `cluster-logging-operator/` (config generation may need updates) |
