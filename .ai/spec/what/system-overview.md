# System Overview

Red Hat OpenShift Logging 6.x provides cluster-level log collection, forwarding, storage, and visualization for OpenShift Container Platform. It collects application, infrastructure, and audit logs using Vector, forwards them to configurable destinations via ClusterLogForwarder, optionally stores them in a managed LokiStack, and visualizes them through an OpenShift Console plugin.

## Behavioral Rules

### System Role

1. The product collects logs from three categories: application container logs, infrastructure logs (system containers + node journal), and audit logs (Kubernetes API, OpenShift API, auditd, OVN). `[GA]`
2. The product forwards collected logs to one or more configured output destinations. `[GA]`
3. The product optionally stores logs in a managed LokiStack for querying and alerting. `[GA]`
4. The product optionally provides a web console UI for log exploration. `[GA, via COO support exception]`

### Component Inventory

5. **Red Hat OpenShift Logging Operator (CLO)** manages the `ClusterLogForwarder` CR to deploy and configure Vector-based log collectors. Installed in `openshift-logging` namespace. `[GA]`
6. **Loki Operator** manages `LokiStack`, `AlertingRule`, `RecordingRule`, and `RulerConfig` CRs for log storage. Installed in `openshift-operators-redhat` namespace. `[GA]`
7. **Cluster Observability Operator (COO)** deploys the Logging UI Plugin via the `UIPlugin` CR. COO itself is Technology Preview, but the Logging UI Plugin has a support exception making it GA for logging use on OCP 4.14+. `[TP with support exception]`
8. **Vector** is the sole supported log collector implementation. `[GA]` `[PLANNED: replaced by OpenTelemetry Collector as default, see what/collector-migration.md]`
9. **OpenTelemetry Collector** is available as an alternative collector backend when `spec.collector.type: OTELCollector` is set on the ClusterLogForwarder. Requires the OTEL Operator. `[PLANNED, TP]`
10. **Fluentd** is deprecated — bug fixes only, no enhancements, planned removal. `[DEPRECATED]`
11. **Kibana** is deprecated — planned removal. `[DEPRECATED]`

### Supported APIs

12. `ClusterLogForwarder` (`observability.openshift.io/v1`) — primary API for log collection and forwarding. `[GA, since 6.0]`
13. `LogFileMetricExporter` (`logging.openshift.io/v1alpha1`) — Prometheus metrics about log file volume. `[GA, since 5.8]`
14. `LokiStack` (`loki.grafana.com/v1`) — managed Loki deployment. `[GA, since 5.5]`
15. `AlertingRule` (`loki.grafana.com/v1`) — log-based alerting rules. `[GA, since 5.7]`
16. `RecordingRule` (`loki.grafana.com/v1`) — log-based recording rules. `[GA, since 5.7]`
17. `RulerConfig` (`loki.grafana.com/v1`) — Loki ruler configuration. `[GA, since 5.7]`

### Data Models

18. **ViaQ** is the default data model used by all output types. `[GA]`
19. **OpenTelemetry (OTEL)** data model is available for OTLP output and LokiStack output with `dataModel: Otel`. Requires Technology Preview annotation on the ClusterLogForwarder. `[TP]`

### Lifecycle

20. Operators are installed via OLM (Operator Lifecycle Manager) from OperatorHub.
21. CLO and Loki Operator can be installed independently — CLO does not require Loki Operator if forwarding to external destinations only.
22. The Logging UI Plugin requires both the Loki Operator (for LokiStack) and COO (for UIPlugin CR).
23. When using the OTEL Collector backend, the OTEL Operator must also be installed. `[PLANNED]`

## Configuration Surface

| CR | Required | Purpose |
|---|---|---|
| `ClusterLogForwarder` | Yes (for collection) | Defines inputs, outputs, filters, pipelines, and collector settings |
| `LokiStack` | No (only for Loki storage) | Deploys managed Loki instance with multitenancy |
| `AlertingRule` | No | Defines log-based alerting rules for Loki ruler |
| `RecordingRule` | No | Defines log-based recording rules for Loki ruler |
| `RulerConfig` | No | Configures Loki ruler (AlertManager, remote write) |
| `LogFileMetricExporter` | No | Exposes Prometheus metrics about log file processing |
| `UIPlugin` | No (only for UI) | Deploys logging console plugin via COO |

## Constraints

- Only one `ClusterLogForwarder` per namespace is expected. Multiple instances across different namespaces are supported for multi-tenant collection.
- The `serviceAccount` field on `ClusterLogForwarder` is required — the operator uses RBAC on the SA to determine which log types (application, infrastructure, audit) the forwarder is authorized to collect.
- Vector is the default collector. OpenTelemetry Collector is available as an alternative via `spec.collector.type`. `[PLANNED: see what/collector-migration.md]`
- LokiStack requires object storage (S3, Azure Blob, GCS, Swift, or S3-compatible) — there is no local storage option for production.

## Planned Changes

| Ticket | Summary |
|---|---|
| — | Removal of Fluentd collector (deprecated) |
| — | Removal of Kibana (deprecated) |
| — | Removal of `azureMonitor` output type (Microsoft disabling Data Collector API September 2026) |
| — | Migration from Vector to OpenTelemetry Collector (see `what/collector-migration.md`) |
