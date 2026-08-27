# OpenTelemetry Event Collection `[PLANNED]`

Kubernetes event collection using the OpenTelemetry Collector instead of the standalone eventrouter service. Eliminates the need for a separate eventrouter container image while preserving the eventrouter JSON output format for backward compatibility with Vector ViaQ normalization.

## Behavioral Rules

### Architecture

1. Event collection is deployed as an **OpenTelemetryCollector** CR (managed by the OTEL Operator) with `mode: deployment` and `replicas: 1`. It is **not** managed by the cluster-logging-operator. `[PLANNED]`
2. The OTEL event collector uses **k8sobjectsreceiver** (watch mode) to watch `core/v1` `Event` resources via the Kubernetes watch API. `[PLANNED]`
3. The OTEL event collector uses **eventrouterexporter** (custom RHBOO component) to write eventrouter-compatible JSON to stdout. `[PLANNED]`
4. The main log collector (Vector or OTEL collector) picks up the event collector's container logs as **infrastructure** logs when the event collector is deployed in an operations namespace (e.g., `openshift-logging`). `[PLANNED]`
5. The event collector MUST run as a single replica. k8sobjectsreceiver watch mode does not support leader election; multiple replicas would duplicate events. `[PLANNED]`

### Watch Behavior

6. The event collector watches `core/v1` `Event` resources using k8sobjectsreceiver configured with `mode: watch` and `exclude_watch_type: [DELETED]`. `[PLANNED]`
7. Event **create** (`ADDED`) and **update** (`MODIFIED`) notifications are forwarded to the exporter. Event **delete** notifications are excluded (same as current eventrouter — deletes occur only on TTL expiry and carry no new information). `[PLANNED]`

### Namespace Scoping

8. The `namespaces` array in the k8sobjectsreceiver config scopes the watch to specific namespaces. When empty (`namespaces: []`), the event collector watches events cluster-wide across all namespaces. `[PLANNED]`
9. Unlike the current eventrouter's single `WATCH_NAMESPACE` environment variable, the OTEL event collector supports watching **multiple specific namespaces** via the array (e.g., `namespaces: [default, my-namespace]`). `[PLANNED]`

### Output Format

10. Each emitted record is a single-line JSON object with fields `verb` (`ADDED` or `UPDATED`) and `event` (the full `v1.Event` object). The `old_event` field is **omitted** (not included in the output). `[PLANNED]`
11. The `verb` value is derived from the watch event type: `ADDED` watch events produce `"verb": "ADDED"`, and `MODIFIED` watch events produce `"verb": "UPDATED"`. `[PLANNED]`
12. The `event` field contains the complete `v1.Event` object as received from the Kubernetes watch API. `[PLANNED]`

### Deployment

13. The event collector is deployed manually by creating an `OpenTelemetryCollector` CR. It is **not** automatically deployed or managed by the cluster-logging-operator. `[PLANNED]`
14. Deployment requires a `ServiceAccount`, a `ClusterRole` granting `get`, `watch`, and `list` on `events`, and a `ClusterRoleBinding`. `[PLANNED]`
15. The event collector MUST be deployed into an operations namespace (e.g., `openshift-logging`) so that its logs are collected as **infrastructure** log-type by the main collector. `[PLANNED]`
16. The container image is distributed via the Red Hat Build of OpenTelemetry (RHBOO) distribution: `registry.redhat.io/rhboo/opentelemetry-collector-rhel8`. `[PLANNED]`
17. The OTEL Operator MUST be installed in the cluster before deploying the event collector. The event collector CR will fail to reconcile if the OTEL Operator is not present. `[PLANNED]`

### Downstream Processing

18. The event collector only emits raw event JSON to stdout. Parsing and ViaQ shaping of these records (lifting the nested `event` object, deriving `@timestamp`, the `EventRouterLog` data model) is performed by the main collector — see `what/log-collection.md` and `what/log-forwarding.md`. `[PLANNED]`
19. The ViaQ normalization in Vector extracts the `verb` field to `.kubernetes.event.verb` and the `event` object to `.kubernetes.event`. The absence of `old_event` does not affect processing. `[PLANNED]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `spec.mode` | enum | — | Deployment mode: `deployment` (required for event collection). |
| `spec.replicas` | int | — | Number of replicas. MUST be `1` for event collection. |
| `spec.serviceAccount` | string | — | ServiceAccount name (required). |
| `spec.config.receivers.k8s_objects.auth_type` | enum | `serviceAccount` | Authentication method: `serviceAccount`, `kubeConfig`, or `none`. |
| `spec.config.receivers.k8s_objects.objects[].name` | string | — | Kubernetes resource name. MUST be `events` for event collection. |
| `spec.config.receivers.k8s_objects.objects[].mode` | enum | — | Collection mode: `watch` or `pull`. MUST be `watch` for event collection. |
| `spec.config.receivers.k8s_objects.objects[].exclude_watch_type` | []enum | — | Watch event types to exclude: `ADDED`, `MODIFIED`, `DELETED`, `BOOKMARK`, `ERROR`. MUST include `DELETED` for eventrouter parity. |
| `spec.config.receivers.k8s_objects.objects[].namespaces` | []string | `[]` (all) | Namespaces to watch. Empty array watches all namespaces. |
| `spec.config.exporters.eventrouter` | object | — | Eventrouterexporter configuration (outputs to stdout). |

## Constraints

- Single replica only. There is no leader election for k8sobjectsreceiver watch mode, so scaling beyond one replica duplicates forwarded events.
- Requires manual deployment. The cluster-logging-operator does not create, reconcile, or manage the event collector.
- Requires OTEL Operator. The `OpenTelemetryCollector` CRD must be registered in the cluster before deploying the event collector.
- The `old_event` field is not populated. The watch API does not provide the previous version of an object; only Informers with client-side caching (like the current eventrouter) can provide this. The field is omitted from the output.
- The `ClusterRole` grants cluster-wide read on `events` even when `namespaces` restricts the actual watch scope (same as current eventrouter).

## Differences from Current Eventrouter

| Aspect | Eventrouter | OTEL Event Collection |
|--------|-------------|----------------------|
| Deployment | Manual YAML manifest (`Deployment`) | Manual OpenTelemetryCollector CR |
| Image | `registry.redhat.io/openshift-logging/eventrouter-rhel8` | `registry.redhat.io/rhboo/opentelemetry-collector-rhel8` |
| Watch mechanism | Informer (client-side cache) | Watch API (stateless) |
| Output: `verb` | `ADDED` / `UPDATED` | `ADDED` / `UPDATED` |
| Output: `event` | Full `v1.Event` | Full `v1.Event` |
| Output: `old_event` | Populated (from Informer cache) | **Omitted completely** |
| Namespace scoping | Single namespace or all (`WATCH_NAMESPACE` env var) | Multiple namespaces or all (`namespaces` array) |
| Prometheus metrics | Go runtime metrics at `:8080/metrics` | None (OTEL collector has its own telemetry) |
| DELETE events | Not forwarded | Not forwarded |
| Prerequisites | None | OTEL Operator installed |

## Migration from Eventrouter

1. Install the OTEL Operator in the cluster (if not already present).
2. Create the event collector `ServiceAccount`, `ClusterRole`, and `ClusterRoleBinding` (same RBAC as eventrouter).
3. Deploy the `OpenTelemetryCollector` CR to the same namespace where the eventrouter was deployed (typically `openshift-logging`).
4. Verify the event collector pod is running and events appear in the logs.
5. Delete the eventrouter `Deployment`, `ConfigMap`, and related resources.
6. The main log collector (Vector or OTEL) continues to collect the event collector's container logs with no configuration changes.

## Impact on Existing Specs

When this feature ships:

| Spec | Current statement | Required update |
|---|---|---|
| `what/event-router.md` | Documents the standalone eventrouter service | Mark as deprecated; add forward reference to `what/otel-event-collection.md` |
| `what/feature-support-matrix.md` | Eventrouter listed as GA | Add OTEL event collection as TP, mark eventrouter as deprecated |
| `how/repo-map.md` | `eventrouter/` listed for event collection | Add `redhat-opentelemetry-collector/exporter/eventrouterexporter` |
