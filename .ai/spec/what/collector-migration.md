# Collector Migration — Vector to OpenTelemetry Collector

The product migrates from Vector to OpenTelemetry Collector as the log collection backend. The migration is phased: users first choose the collector backend, then OTEL Collector becomes the default, and finally the ClusterLogForwarder CRD may be consolidated into the OTEL Operator. The ClusterLogForwarder API remains the user-facing CRD throughout — no breaking CRD changes.

## Behavioral Rules

### Phased Migration

1. **Phase 1 — Collector Choice.** Users select the collector backend via `spec.collector.type` on ClusterLogForwarder. Values: `Vector` (default) and `OTELCollector`. `[PLANNED, TP]`
2. **Phase 2 — OTEL Collector Default.** `OTELCollector` becomes the default value for `spec.collector.type`. Vector is deprecated (bug fixes only). Users who explicitly set `Vector` continue to work. `[PLANNED, GA]`
3. **Phase 3 — Consolidation.** Options remain open. One possibility: the OTEL Operator adopts the ClusterLogForwarder CRD directly (same API group, same version, same spec), and CLO is retired with no user-facing CRD change. This phase is deliberately unspecified — Phase 1 and 2 inform it. `[PLANNED]`

### Operator Cooperation

4. When `spec.collector.type: OTELCollector`, CLO creates an `OpenTelemetryCollector` CR in the same namespace. The OTEL Operator reconciles it. CLO does not deploy the collector itself. `[PLANNED]`
5. The generated `OpenTelemetryCollector` CR is named `<clf-name>-logging` to avoid collisions with user-created OTEL collectors. `[PLANNED]`
6. CLO sets owner references on the generated CR. Deleting the CLF garbage-collects the `OpenTelemetryCollector` CR. `[PLANNED]`
7. CLO watches the `OpenTelemetryCollector` CR status and reflects collector health back into CLF status conditions. `[PLANNED]`
8. The OTEL Operator has no logging-specific awareness — it reconciles the `OpenTelemetryCollector` CR as it would any other. `[PLANNED]`

### Prerequisites

9. The OTEL Operator must be installed on the cluster when `spec.collector.type: OTELCollector` is selected. CLO validates this and sets a degraded status condition if the CRD is absent. `[PLANNED]`
10. Phase 1 requires the Technology Preview annotation on the ClusterLogForwarder. `[PLANNED]`

### Collector Image

11. The OTEL Collector path uses the same shared collector image that the OTEL product ships (FIPS-compliant, UBI9-based, multi-arch). Components required for logging are added to the shared `manifest.yaml`. `[PLANNED]`

### Mode Mapping

12. CLF with node-level inputs (application, infrastructure, audit) maps to `OpenTelemetryCollector` with `mode: daemonset`. `[PLANNED]`
13. CLF with receiver-only inputs maps to `OpenTelemetryCollector` with `mode: deployment`. `[PLANNED]`

### Resource Passthrough

14. CLF `spec.collector.resources`, `nodeSelector`, `tolerations`, `affinity` map directly to the corresponding fields on the generated `OpenTelemetryCollector` CR. `[PLANNED]`

### Config Translation — Inputs

15. CLF `application` input maps to a `filelog` receiver with include paths for `/var/log/pods/` excluding infrastructure namespaces. Namespace and container include/exclude filters become filelog path patterns. `[PLANNED]`
16. CLF `infrastructure` container input maps to a `filelog` receiver with include paths for infrastructure namespace pods (`default`, `kube-*`, `openshift-*`). `[PLANNED]`
17. CLF `infrastructure` node input maps to a `journald` receiver. `[PLANNED]`
18. CLF `audit` inputs map to `filelog` receivers reading the appropriate audit log file paths (`/var/log/kube-apiserver/`, `/var/log/openshift-apiserver/`, `/var/log/audit/audit.log`, `/var/log/ovn/`). `[PLANNED]`
19. CLF `receiver` (HTTP) input maps to an OTLP or HTTP receiver. `[PLANNED]`
20. CLF `receiver` (syslog) input maps to a `syslog` receiver. `[PLANNED]`

### Config Translation — Filters

21. CLF `drop` filter maps to a `filter` processor with OTTL conditions. `[PLANNED]`
22. CLF `prune` filter maps to a `transform` processor with OTTL field delete/keep statements. `[PLANNED]`
23. CLF `kubeAPIAudit` filter maps to a `filter` processor with OTTL conditions on audit level/verb/resource. `[PLANNED]`
24. CLF `openshiftLabels` filter maps to a `transform` processor with OTTL `set` statements. `[PLANNED]`
25. CLF `parse` (JSON) filter maps to a `transform` processor with OTTL JSON parsing. `[PLANNED]`
26. CLF `detectMultilineException` filter maps to the filelog receiver's `multiline` operator at ingestion time. `[PLANNED]`

### Config Translation — Outputs

27. All current GA output types must be supported with the OTEL Collector backend. Missing exporters are added to the shared collector distro from upstream contrib. Output mapping details are investigated separately. `[PLANNED]`
28. CLF `lokiStack` output maps to an `otlphttp` exporter (LokiStack already supports OTLP ingestion). `[PLANNED]`
29. CLF `otlp` output maps to `otlp`/`otlphttp` exporters. `[PLANNED]`
30. CLF `kafka` output maps to a `kafka` exporter. `[PLANNED]`

### Config Translation — Pipeline Wiring

31. CLF pipelines (inputRefs -> filterRefs -> outputRefs) are translated into OTEL Collector `service.pipelines` entries. The `routing` connector handles fan-out to multiple exporters. `[PLANNED]`

### Config Translation — Templating

32. CLF template expressions (`{.field.path||"fallback"}`) are translated into OTTL expressions within `transform` or `routing` processors. Behavior must be identical to the Vector path. `[PLANNED]`

### Kubernetes Metadata Enrichment

33. The `k8sattributes` processor is always injected into the pipeline to enrich logs with pod name, namespace, labels, and node name. `[PLANNED]`

### Data Model Compatibility

34. The CLF `dataModel` field controls output format for both collector backends. `[PLANNED]`
35. When `dataModel: Viaq`, CLO injects `transform` processors to reshape OTEL-native log records into ViaQ schema (field mapping, timestamp conventions, log type metadata). Downstream destinations see output identical to the Vector path. `[PLANNED]`
36. When `dataModel: Otel`, no reshaping is applied — OTEL-native log records flow through as-is. `[PLANNED]`
37. If maintaining ViaQ transforms in the OTEL Collector path becomes too costly, ViaQ support for the OTEL path may be dropped. `[PLANNED]`

### Status Reporting

38. CLF status conditions include `CollectorType`, `CollectorReady` (reflecting the `OpenTelemetryCollector` CR status), and `OTELOperatorAvailable`. `[PLANNED]`

### User Migration Experience

39. Users can switch between `Vector` and `OTELCollector` at any time. Switching deletes the previous collector's resources and creates the new ones. `[PLANNED]`
40. Users can run two CLF instances in different namespaces — one with each collector — to compare output before committing. `[PLANNED]`

## OTEL Collector Distro Prerequisites

### Components to Add

41. Exporters from upstream contrib: `elasticsearch`, `splunk_hec`, `syslog`, `awss3`, `loki`, and an Azure exporter (needs investigation). `[PLANNED]`
42. Receivers from upstream contrib: `syslog` receiver. `[PLANNED]`

### Components to Promote to GA

43. `journald` receiver (infrastructure node journal collection). `[PLANNED]`
44. `awscloudwatchlogs` exporter (CloudWatch output). `[PLANNED]`
45. `googlecloud` exporter (Google Cloud Logging output). `[PLANNED]`
46. `routing` connector (multi-output pipeline fan-out). `[PLANNED]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.collector.type` | enum | `Vector` | Collector backend: `Vector` or `OTELCollector` `[PLANNED]` |

## Constraints

- The OTEL Operator must be installed when `OTELCollector` is selected.
- Phase 1 requires the Technology Preview annotation on the CLF.
- The Vector path remains fully functional and unchanged throughout all phases.
- Both collectors must produce identical output for the same CLF configuration and data model.
- No breaking changes to the ClusterLogForwarder CRD at any phase.
