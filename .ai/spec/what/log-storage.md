# Log Storage

LokiStack provides managed log storage with multitenancy, retention policies, alerting rules, and recording rules. The Loki Operator deploys and manages all Loki components. Logs are stored in object storage (S3, Azure Blob, GCS, Swift, or S3-compatible).

## Behavioral Rules

### LokiStack Deployment

1. LokiStack deploys a complete Loki instance: distributor, ingester, querier, query frontend, compactor, index gateway, ruler, and gateway. `[GA]`
2. LokiStack supports predefined size presets: `1x.demo`, `1x.extra-small`, `1x.small`, `1x.medium`. `[GA]`
3. Individual Loki component pod templates (resources, nodeSelector, tolerations) are configurable. `[GA]`
4. Setting resource limits equal to resource requests for LokiStack components is available. `[TP]`

### Multitenancy

5. LokiStack enforces multitenancy with three log tenants: `application`, `infrastructure`, `audit`. `[GA]`
6. Tenant mode `openshift-logging` provides fully automatic OpenShift in-cluster authentication and authorization. `[GA]`
7. Fine-grained log access control is supported via RBAC: cluster-wide reader, namespace-scoped reader, and custom admin groups. `[GA]`

### Object Storage Backends

8. **AWS S3** is supported as object storage. `[GA]`
9. **Azure Blob Storage** is supported as object storage. `[GA]`
10. **Google Cloud Storage (GCS)** is supported as object storage. `[GA]`
11. **Swift** (OpenStack) is supported as object storage. `[GA]`
12. **S3-compatible storage** (e.g., NetApp StorageGRID, MinIO) is supported. `[GA]`
13. **Red Hat OpenShift Data Foundation** (Ceph RGW) is supported. `[GA]`
14. **Alibaba Cloud OSS** is supported in the Loki Operator source code but is not documented. `[UNSUPPORTED]`
15. TLS CA bundles are supported for object storage endpoints. `[GA]`
16. `forcepathstyle` is supported in the LokiStack storage secret for S3-compatible stores. `[GA]` (new in 6.3)

### Cloud Credential Management

17. Workload Identity Federation is supported for AWS (STS), Azure (Entra ID), and GCP (WIF). `[GA]`
18. Short-lived credential provisioning via `ccoctl` is supported. `[GA]`

### Retention

19. Stream-based retention policies are configurable at global and per-tenant levels. `[GA]`

### Zone-Aware Replication

20. Zone-aware data replication distributes log data across failure domains. `[GA]`
21. The `replicationFactor` field is deprecated — use `replication.factor` instead. `[DEPRECATED]`

### Alerting and Recording Rules

22. `AlertingRule` CR defines Prometheus-style alerting rules evaluated by the Loki ruler against log data. `[GA]`
23. `RecordingRule` CR defines recording rules that pre-compute log-based metrics. `[GA]`
24. `RulerConfig` CR configures the Loki ruler: AlertManager URL, remote write endpoints, notification settings. `[GA]`

### Schema and Ingestion

25. Schema versions v12 and v13 are supported. `[GA]`
26. OTLP ingestion in LokiStack is supported (requires schema v13). `[GA]` (for the LokiStack ingestion side; using OTEL data model from CLO is `[TP]`)
27. Custom OTLP attribute mapping in LokiStack is configurable. `[GA]`

### LokiStack Size Presets

28. `1x.pico` size preset exists in the Loki Operator source code but is not documented. `[UNSUPPORTED]`

### Tenant Modes (Loki Operator)

29. `openshift-network` tenant mode provides automatic OpenShift auth for network-specific log flows. It exists in the Loki Operator source code. `[UNSUPPORTED]` (not documented for logging use)
30. `static`, `dynamic`, `passthrough` tenant modes exist in the Loki Operator source code for non-OpenShift deployments. `[UNSUPPORTED]` (not documented for Red Hat OpenShift Logging)

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.size` | enum | — | `1x.demo`, `1x.extra-small`, `1x.small`, `1x.medium` |
| `spec.storage.secret.name` | string | — | Secret with object storage credentials |
| `spec.storage.secret.type` | enum | — | `s3`, `azure`, `gcs`, `swift` |
| `spec.storage.tls.caName` | string | — | ConfigMap with CA bundle for storage TLS |
| `spec.storage.schemas[].version` | enum | — | `v12`, `v13` |
| `spec.tenants.mode` | enum | — | `openshift-logging` (for OpenShift Logging) |
| `spec.limits.global.retention` | RetentionConfig | — | Global retention policy |
| `spec.limits.tenants` | map | — | Per-tenant retention and query limits |
| `spec.replication.factor` | int | — | Zone-aware replication factor |
| `spec.template.<component>` | PodTemplateSpec | — | Per-component pod template overrides |

## Constraints

- LokiStack requires an external object storage backend — no local storage for production.
- Schema v13 is required for OTLP ingestion.
- The `1x.demo` size is not intended for production use.
- AlertingRule and RecordingRule CRs must be in the same namespace as the LokiStack they target.
