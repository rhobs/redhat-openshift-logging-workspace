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
8. **Vector** is the sole supported log collector implementation. `[GA]`
9. **Log File Metric Exporter** is a standalone Prometheus exporter binary (repo `github.com/ViaQ/log-file-metric-exporter`) deployed by CLO as a separate DaemonSet in response to a `LogFileMetricExporter` CR. It measures bytes actually written to pod log files. See `what/log-file-metric-exporter.md`. `[GA]`

### Supported APIs

10. `ClusterLogForwarder` (`observability.openshift.io/v1`) — primary API for log collection and forwarding. `[GA]`
11. `LogFileMetricExporter` (`logging.openshift.io/v1alpha1`) — Prometheus metrics about log file volume. `[GA]`
12. `LokiStack` (`loki.grafana.com/v1`) — managed Loki deployment. `[GA]`
13. `AlertingRule` (`loki.grafana.com/v1`) — log-based alerting rules. `[GA]`
14. `RecordingRule` (`loki.grafana.com/v1`) — log-based recording rules. `[GA]`
15. `RulerConfig` (`loki.grafana.com/v1`) — Loki ruler configuration. `[GA]`

### Data Models

16. **ViaQ** is the default data model used by all output types. `[GA]`
17. **OpenTelemetry (OTEL)** data model is available for OTLP output and LokiStack output with `dataModel: Otel`. `[TP]`

### Lifecycle

18. Operators are installed via OLM (Operator Lifecycle Manager) from OperatorHub.
19. CLO and Loki Operator can be installed independently — CLO does not require Loki Operator if forwarding to external destinations only.
20. The Logging UI Plugin requires both the Loki Operator (for LokiStack) and COO (for UIPlugin CR).

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
- Vector is the only collector; there is no pluggable collector interface.
- LokiStack requires object storage (S3, Azure Blob, GCS, Swift, or S3-compatible) — there is no local storage option for production.

## Planned Changes

| Ticket | Summary |
|---|---|
| — | Removal of `azureMonitor` output type (Microsoft disabling Data Collector API September 2026) |
