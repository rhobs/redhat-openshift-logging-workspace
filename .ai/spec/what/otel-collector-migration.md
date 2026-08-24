# OTEL Collector Migration `[PLANNED]`

Replacing Vector with the OpenTelemetry Collector from Red Hat Build of OpenTelemetry (RHBOO) as the log collection and forwarding backend in CLO. All features described in this spec are `[PLANNED]` unless otherwise noted.

## Goals

1. **Seamless migration** — customers switch collector backend via a single field; no changes to inputs, outputs, filters, or pipelines.
2. **Feature parity** — all CLF output types, filters, and features work with the OTEL collector.
3. **Maintain CLO APIs** — `ClusterLogForwarder` v1 API is preserved; no breaking changes.
4. **Avoid two stacks** — Vector is retained during transition but the end state is OTEL-only.
5. **Simple stack** — CLO delegates deployment to the OTEL Operator rather than managing the collector itself.

## Architecture

### [PLANNED] CLO Orchestrates OTEL Operator

When `spec.collector.type: otel`, CLO translates the `ClusterLogForwarder` spec into an `OpenTelemetryCollector` CR. The OTEL Operator (pre-installed in the cluster) reconciles that CR and deploys the collector.

```
Customer → ClusterLogForwarder (type: otel)
              │
              ▼
         CLO Controller
           1. Validate OTEL Operator present
           2. Validate outputs are OTEL-supported
           3. Translate CLF → OpenTelemetryCollector CR
           4. Create/update CR with ownerReference → CLF
              │
              ▼
         OTEL Operator
           Reconciles OpenTelemetryCollector CR
           Deploys DaemonSet/Deployment
```

When `spec.collector.type: vector` (default), CLO behaves exactly as today — generates Vector TOML config and deploys the Vector DaemonSet directly.

### Rules

1. CLO MUST validate that the `OpenTelemetryCollector` CRD is registered in the cluster when `type: otel` is set. If missing, CLO MUST set status condition `Ready=False, Reason=OTELOperatorNotFound`.
2. CLO MUST validate that all output types in the CLF are supported with the OTEL backend. Unsupported outputs MUST produce `Ready=False, Reason=UnsupportedOTELOutput` with a message naming the unsupported output and type.
3. CLO MUST create the `OpenTelemetryCollector` CR in the same namespace as the `ClusterLogForwarder`.
4. CLO MUST set `ownerReferences` on the `OpenTelemetryCollector` CR pointing to the `ClusterLogForwarder`, so it is garbage-collected on CLF deletion.
5. CLO MUST derive the `OpenTelemetryCollector` CR name from the CLF name.
6. CLO MUST pass collector-level settings (resources, nodeSelector, tolerations) through to the `OpenTelemetryCollector` CR.
7. Rollback: when `type` changes from `otel` to `vector`, CLO MUST delete the `OpenTelemetryCollector` CR (or let ownerReference GC handle it) and create the Vector DaemonSet config.

## API Changes

### [PLANNED] spec.collector.type

A new field on `ClusterLogForwarder` `observability.openshift.io/v1`:

```yaml
spec:
  collector:
    type: otel    # enum: vector | otel, default: vector
```

All other CLF fields (inputs, outputs, filters, pipelines, serviceAccount, collector.resources, collector.nodeSelector, collector.tolerations) retain identical semantics regardless of collector type.

### Rules

8. The `type` field MUST default to `vector`.
9. All existing CLF fields MUST have identical configuration semantics for both collector types — the same CLF spec produces the same forwarding behavior. The customer's CLF MUST NOT require changes other than setting `collector.type` to switch backends. Note: the wire-level data format may differ if the data model differs (see Data Model section); "identical semantics" refers to the CLF configuration surface, not the serialized payload.

## CLF-to-OpenTelemetryCollector Translation

### Inputs → Receivers

| CLF Input | OTEL Receiver | Configuration |
|---|---|---|
| `application` (containers) | `filelog` | `include: [/var/log/pods/*/*/*.log]`, exclude infra namespaces |
| `infrastructure` (containers) | `filelog` | `include: [/var/log/pods/*/*/*.log]`, include only `openshift-*`, `kube-*`, `default` namespaces |
| `infrastructure` (journal) | `journald` | `directory: /var/log/journal` |
| `audit` (k8s API) | `filelog` | `include: [/var/log/kube-apiserver/audit.log]` |
| `audit` (openshift API) | `filelog` | `include: [/var/log/openshift-apiserver/audit.log]` |
| `audit` (auditd) | `filelog` | `include: [/var/log/audit/audit.log]` |
| `audit` (OVN) | `filelog` | `include: [/var/log/ovn/acl-audit-log.log]` |
| `receiver` (HTTP) | `otlp` or `http` | Per CLF receiver spec |
| `receiver` (syslog) | `syslog` | Per CLF receiver spec |

### Filters → Processors

| CLF Filter | OTEL Processor | Notes |
|---|---|---|
| `drop` | `filter` | OTTL conditions matching drop test expressions |
| `prune` | `transform` | `delete_key()` for excluded fields |
| `kubeAPIAudit` | `transform` | OTTL statements pruning audit event fields |
| `openshiftLabels` | `transform` | `set()` to add static labels as attributes |
| `parse` (JSON) | `transform` | `ParseJSON(log.body)` into attributes |
| `detectMultilineException` | Custom processor | Gap — requires upstream contribution or custom component |

### Outputs → Exporters

| CLF Output | OTEL Exporter | RHBOO Distro Status |
|---|---|---|
| `lokiStack` | `otlp` / `otlphttp` | GA |
| `otlp` | `otlp` / `otlphttp` | GA |
| `kafka` | `kafka` | GA |
| `cloudwatch` | `awscloudwatchlogs` | TP |
| `googleCloudLogging` | `googlecloud` | TP |
| `elasticsearch` | `elasticsearch` | Needs adding |
| `splunk` | `splunkhec` | Needs adding |
| `syslog` | `syslog` | Needs adding |
| `http` | TBD | Needs investigation |
| `loki` (standalone) | `loki` | Needs adding |
| `s3` | `awss3` | Needs adding |
| `azureLogsIngestion` | TBD | Needs investigation |

### Common Processors (always injected)

CLO MUST inject these processors into every OTEL pipeline:

| Processor | Purpose |
|---|---|
| `k8sattributes` | Enrich logs with pod/namespace/node metadata |
| `resource` | Inject `openshift.cluster_id`, `log_type`, `log_source` |
| `resourcedetection` | Detect node name |
| `batch` | Batching for performance |
| `memorylimiter` | Memory protection |

### Pipelines → Service

CLF pipelines (inputRefs → filterRefs → outputRefs) map to the OTEL Collector `service.pipelines` section. CLO generates unique pipeline IDs from CLF pipeline names, connecting the translated receivers → processors → exporters.

### Rules

10. CLO MUST inject common processors (k8sattributes, resource, resourcedetection, batch, memorylimiter) into every generated OTEL pipeline.
11. CLO MUST translate CLF RBAC authorization (service account-based log type gating) to equivalent access controls in the OTEL collector configuration.
12. CLO MUST configure appropriate volume mounts for log file paths in the `OpenTelemetryCollector` CR.

## Data Model

### [PLANNED] ViaQ Support — Separate Investigation

Whether the OTEL collector should support the ViaQ data model (producing identical JSON output to Vector) is a separate decision. Preliminary analysis shows it is feasible but hard, with key gaps in OTTL:

- Multi-line exception detection (no OTEL collector equivalent to Vector's `detect_exceptions`)
- Dedotting label keys (OTTL lacks looping over map keys)
- klog parsing (no OTTL equivalent)

This will be investigated and decided separately. The initial OTEL collector deployment will use the OTEL-native data model.

### Rules

13. When `type: otel`, the data model used MUST be documented and communicated to customers. If ViaQ is not supported, the migration guide MUST list field mapping differences.

## Migration Order

### Phase 1: Foundation

Before any output type can ship with OTEL support:

- `spec.collector.type` field added to CLF API
- OTEL Operator presence validation and status reporting
- `OpenTelemetryCollector` CR generation scaffolding (lifecycle, ownerRef, namespace, naming)
- Common processor chain
- Input/receiver translation (filelog, journald for all log types)
- RBAC authorization with OTEL collector
- Volume mounts for log paths

### Phase 2: Outputs Already in RHBOO Distro

Delivered in order of customer usage and risk:

1. **LokiStack** (via OTLP) — highest usage, exporter GA, validates full pipeline end-to-end
2. **OTLP** — trivial, exporter GA
3. **Kafka** — exporter GA, widely used
4. **CloudWatch** — exporter in distro (TP)
5. **Google Cloud Logging** — exporter in distro (TP)

### Phase 3: Outputs Needing Distro Addition

Each requires: add exporter to RHBOO `manifest.yaml` → productize → implement CLO translation.

6. **Elasticsearch** — `elasticsearchexporter` in upstream contrib
7. **Splunk HEC** — `splunkhecexporter` in upstream contrib
8. **Syslog** — `syslogexporter` in upstream contrib
9. **HTTP** — needs investigation
10. **Loki standalone** — `lokiexporter` in upstream contrib
11. **S3** — `awss3exporter` in upstream contrib
12. **Azure Logs Ingestion** — needs investigation

### Phase 4: Feature Parity Completion

- `detectMultilineException` — custom OTEL processor
- Rate limiting parity
- Delivery mode parity (AtLeastOnce via `filestorage` extension)
- ViaQ data model support (if decided)

### Phase 5: Default Flip and Vector Deprecation

- Change `spec.collector.type` default from `vector` to `otel`
- Deprecation notice for `type: vector`
- Remove Vector code path from CLO

### Rules

14. At any point during rollout, if a customer sets `type: otel` with an output type not yet migrated, CLO MUST reject with a status condition listing the unsupported outputs.
15. Each output type MUST pass parity tests before shipping — send identical logs through both Vector and OTEL paths and compare sink output.

## Cross-Repo Coordination

### Repos Affected

| Repo | Changes |
|---|---|
| **cluster-logging-operator** | `type` field, OTEL config generation, OTEL Operator validation, `OpenTelemetryCollector` CR lifecycle |
| **redhat-opentelemetry-collector** | Add missing exporters to `manifest.yaml` |
| **konflux-opentelemetry** | Productization of new exporters |
| **opentelemetry-operator** | Potentially — if CLO needs unsupported features (volume mounts, RBAC) |
| **data-model-docs** | Update if OTEL data model changes for new output types |
| **logging-view-plugin** | Status/health display of OTEL collector |
| **redhat-openshift-logging-docs** | `spec.collector.type` docs, migration guide, OTEL Operator prerequisite |

### Testing Strategy

**Per-output parity tests:**
- Field presence and values match (or documented as intentionally different)
- Sink-specific protocol fields correctly populated
- Authentication/TLS works identically
- Delivery guarantees hold

**E2E test matrix:**
- Each supported output type with `type: otel`
- Rollback: switch `otel` → `vector`, verify logs resume
- Mixed: CLF with `type: vector` and another with `type: otel` in same cluster
- OTEL Operator missing: verify status error
- Unsupported output: verify rejection with clear message

**Performance benchmarking:**
- Throughput and resource usage comparison (Vector vs OTEL collector)
- `memorylimiter` and `filestorage` vs Vector's rate limiting and disk buffering

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| OTEL Operator doesn't support all volume mount patterns CLO needs | Engage OTEL Operator team early in Phase 1; contribute PRs if needed |
| Exporter behavior differs from Vector sink (retry semantics, batching) | Per-output parity test suite; document behavioral differences |
| Performance regression with OTEL collector vs Vector | Benchmark early in Phase 1; tune batch/memorylimiter config |
| Multi-line exception detection gap | Track as known limitation; contribute upstream processor |
| Upstream OTEL exporter bugs block productization | Pin to validated upstream versions; maintain patch backlog |

## Constraints

- The OTEL Operator MUST be pre-installed by the customer. CLO does not install or manage the OTEL Operator.
- During the dual-stack period, both Vector and OTEL code paths coexist in CLO. This is temporary — the goal is OTEL-only.
- The `detectMultilineException` filter is a known gap with the OTEL collector. It will be tracked as a limitation until a custom processor is built.

## Impact on Existing Specs

When this migration ships, the following existing specs will need updates:

| Spec | Current statement | Required update |
|---|---|---|
| `what/system-overview.md` rule 8 | "Vector is the sole supported log collector implementation" | Add OTEL collector as an alternative when `spec.collector.type: otel` |
| `what/system-overview.md` constraint | "Vector is the only collector; there is no pluggable collector interface" | Update to reflect the `type` field as the collector selection mechanism |
| `what/feature-support-matrix.md` Collector section | "Vector collector \| GA \| Only supported collector" | Add OTEL collector entry with appropriate support level |
| `what/log-collection.md` rule 16-17 | Collector deployed as DaemonSet/Deployment by CLO | Note that with `type: otel`, deployment is delegated to the OTEL Operator |
| `how/repo-map.md` | No OTEL-related repos listed | Add `redhat-opentelemetry-collector`, `opentelemetry-operator`, `konflux-opentelemetry` repos and their concerns |