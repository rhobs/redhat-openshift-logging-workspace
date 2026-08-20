# Feature Support Matrix

Authoritative reference for which features are supported and at what level. A feature is **supported** only if it is documented in the Red Hat OpenShift Logging documentation. Features that exist in source code but are absent from the documentation are **unsupported**.

## Support Levels

| Level | Meaning |
|---|---|
| **GA** | Generally Available. Fully supported in production. |
| **TP** | Technology Preview. Not for production use. May change or be removed without notice. Requires explicit opt-in (annotation or feature gate). |
| **DEPRECATED** | Still functional but planned for removal. Bug fixes only, no enhancements. |
| **UNSUPPORTED** | Exists in source code but is not documented. Not covered by Red Hat support. |

## Operators

| Feature | Status | Notes |
|---|---|---|
| Red Hat OpenShift Logging Operator (CLO) | GA | |
| Loki Operator | GA | |
| Cluster Observability Operator (COO) | TP | Support exception for Logging UI Plugin on OCP 4.14+ |

## APIs / CRDs

| CRD | API Version | Status |
|---|---|---|
| ClusterLogForwarder | `observability.openshift.io/v1` | GA |
| LogFileMetricExporter | `logging.openshift.io/v1alpha1` | GA |
| LokiStack | `loki.grafana.com/v1` | GA |
| AlertingRule | `loki.grafana.com/v1` | GA |
| RecordingRule | `loki.grafana.com/v1` | GA |
| RulerConfig | `loki.grafana.com/v1` | GA |

## Collector

| Feature | Status | Notes |
|---|---|---|
| Vector collector | GA | Only supported collector |
| Collector resource configuration | GA | CPU/memory requests and limits |
| Collector node scheduling (nodeSelector, tolerations) | GA | |
| Collector affinity rules | GA | New in 6.3 |
| Collector log level | GA | |
| Collector maxUnavailable rollout | GA | |
| Collector networkPolicy | GA | |
| managementState (Managed/Unmanaged) | GA | |
| `use-apiserver-cache` attribute | TP | |
| `max-unavailable-rollout` attribute | TP | |
| Metrics collection profiles (minimal/full) | GA | |

## Log Input Types

| Input Type | Status | Notes |
|---|---|---|
| `application` | GA | Container logs from non-infra namespaces |
| `infrastructure` | GA | Infra containers + node journal |
| `audit` | GA | kubeAPI, openshiftAPI, auditd, ovn |
| `receiver` (HTTP) | GA | Limited scope: HyperShift or Red Hat products only |
| `receiver` (syslog) | GA | Limited scope: HyperShift or Red Hat products only |

### Input Tuning

| Feature | Status |
|---|---|
| Namespace includes/excludes (glob) | GA |
| Container includes/excludes (glob) | GA |
| Pod label selectors | GA |
| Rate limit per container | GA |
| Max message size | GA |
| Audit source sub-selection | GA |
| Infrastructure source sub-selection | GA |

## Log Output Types

| Output Type | Status | Notes |
|---|---|---|
| `lokiStack` | GA | Managed LokiStack in-cluster |
| `loki` | GA | External Loki |
| `elasticsearch` | GA | Versions 6, 7, 8, 9 |
| `kafka` | GA | 0.11+, SASL auth |
| `splunk` | GA | HEC, custom index/source |
| `syslog` | GA | RFC 3164/5424, TCP/TLS/UDP |
| `http` | GA | Generic HTTP/HTTPS, JSON/NDJSON |
| `cloudwatch` | GA | AWS access key or STS, cross-account AssumeRole |
| `googleCloudLogging` | GA | Service account or WIF |
| `s3` | GA | S3 or S3-compatible, key prefix templating |
| `azureLogsIngestion` | GA | Logs Ingestion API + DCR, Entra ID WIF |
| `azureMonitor` | DEPRECATED | Microsoft disabling Data Collector API Sept 2026 |
| `otlp` | TP | OpenTelemetry Protocol output |

### Output Common Features

| Feature | Status |
|---|---|
| TLS configuration (CA, cert, key, insecureSkipVerify) | GA |
| TLS security profile selection | GA |
| Rate limiting (maxRecordsPerSecond) | GA |
| Delivery mode (AtLeastOnce / AtMostOnce) | GA |
| Compression (gzip, snappy, zlib, zstd, lz4) | GA |
| Max payload size (maxWrite) | GA |
| Retry tuning (minRetryDuration, maxRetryDuration) | GA |
| Dynamic field templating (`{.field.path}`) | GA |

## Filter Types

| Filter Type | Status | Notes |
|---|---|---|
| `drop` | GA | Field-based regex matching |
| `prune` | GA | In/notIn field removal |
| `kubeAPIAudit` | GA | Audit level filtering |
| `openshiftLabels` | GA | Custom label injection |
| `parse` | GA | JSON parsing |
| `detectMultilineException` | GA | Multi-line stack trace detection |

## Data Models

| Data Model | Status | Notes |
|---|---|---|
| ViaQ | GA | Default for all output types |
| OpenTelemetry (OTEL) | TP | For OTLP output and LokiStack with `dataModel: Otel`; requires TP annotation |

## Log Storage (LokiStack)

| Feature | Status | Notes |
|---|---|---|
| LokiStack deployment | GA | Sizes: demo, extra-small, small, medium |
| Multitenancy (application, infrastructure, audit) | GA | |
| Stream-based retention (global + per-tenant) | GA | |
| Zone-aware data replication | GA | |
| Fine-grained log access (RBAC) | GA | Cluster-wide, namespace-scoped, custom admin groups |
| AlertingRule CR | GA | |
| RecordingRule CR | GA | |
| RulerConfig CR | GA | |
| Schema v12 and v13 | GA | |
| OTLP ingestion in LokiStack | GA | LokiStack side; CLO OTEL data model is TP |
| Custom OTLP attribute mapping | GA | |
| Setting resource limits = requests | TP | |
| `replicationFactor` field | DEPRECATED | Use `replication.factor` |

### LokiStack Storage Backends

| Backend | Status | Notes |
|---|---|---|
| AWS S3 | GA | |
| Azure Blob Storage | GA | |
| Google Cloud Storage (GCS) | GA | |
| Swift (OpenStack) | GA | |
| S3-compatible (NetApp StorageGRID, MinIO) | GA | |
| Red Hat OpenShift Data Foundation (Ceph RGW) | GA | |
| Alibaba Cloud OSS | UNSUPPORTED | In Loki Operator source code, not documented |

### LokiStack Sizes

| Size | Status | Notes |
|---|---|---|
| `1x.demo` | GA | Not for production |
| `1x.extra-small` | GA | |
| `1x.small` | GA | |
| `1x.medium` | GA | |
| `1x.pico` | UNSUPPORTED | In Loki Operator source code, not documented |

### LokiStack Tenant Modes

| Mode | Status | Notes |
|---|---|---|
| `openshift-logging` | GA | Default for OpenShift Logging |
| `openshift-network` | UNSUPPORTED | In source code, not documented for logging |
| `static` | UNSUPPORTED | In source code, not documented for logging |
| `dynamic` | UNSUPPORTED | In source code, not documented for logging |
| `passthrough` | UNSUPPORTED | In source code, not documented for logging |

### Cloud Authentication for Storage

| Method | Status |
|---|---|
| AWS STS (Workload Identity) | GA |
| Azure Entra ID (Workload Identity) | GA |
| GCP WIF (Workload Identity Federation) | GA |
| Short-lived credentials via `ccoctl` | GA |

## Visualization

| Feature | Status | Notes |
|---|---|---|
| Logging UI Plugin | GA | Via COO support exception |
| Admin Observe > Logs page | GA | |
| Pod detail Aggregated Logs tab | GA | |
| Developer perspective Logs tab | GA | Requires `dev-console` feature flag |
| LogQL query input | GA | |
| Time range selection | GA | |
| Log histogram | GA | |
| Virtualized log table | GA | |
| Log detail view | GA | |
| Multi-tenant selector | GA | |
| Streaming (live tail) | GA | |
| Alert integration (admin) | GA | Requires `alerts` feature flag |
| Alert integration (developer) | GA | Requires `dev-alerts` feature flag |
| Schema selector (otel/viaq/select) | GA | otel/select require OCP 4.15+ |
| Timezone selector | GA | |

## Additional Features

| Feature | Status | Notes |
|---|---|---|
| LogFileMetricExporter | GA | Prometheus metrics for log file volume |
| Kubernetes Event Router | GA | Events to stdout for collection |
| Cross-account AWS forwarding (AssumeRole) | GA | |
| Multiple AWS outputs with distinct IAM roles | GA | New in 6.3 |
| Custom collector service account with RBAC-based log authorization | GA | |
| must-gather for support data | GA | |
| S3 `forcepathstyle` in LokiStack secret | GA | New in 6.3 |
| Splunk default metadata key values | GA | New in 6.3 |

## Summary

| Status | Count |
|---|---|
| GA | ~80 features |
| Technology Preview | 5 features (OTLP output, OTEL data model, `use-apiserver-cache`, `max-unavailable-rollout`, LokiStack resource limits=requests) |
| Deprecated | 3 items (azureMonitor, azureMonitor shared key auth, replicationFactor) |
| Unsupported (in code, not in docs) | 5 items (Alibaba Cloud OSS storage, `1x.pico` size, `openshift-network`/`static`/`dynamic`/`passthrough` tenant modes) |
