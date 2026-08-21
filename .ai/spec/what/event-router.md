# Kubernetes Event Router

The Kubernetes Event Router (`openshift/eventrouter`) is a standalone service that watches Kubernetes `core/v1` `Event` resources and writes each event as structured JSON to a configurable **sink**. In Red Hat OpenShift Logging it is deployed manually with the sink set to `stdout`, so the Vector collector picks up its container logs and forwards them like any other workload log. It is **not** managed by the cluster-logging-operator, has no CRD, and is configured through a mounted `config.json` file and environment variables.

## Behavioral Rules

### Watch Behavior

1. The Event Router watches `core/v1` `Event` resources via a Kubernetes shared informer and dispatches each observed event to the configured sink. `[GA]`
2. Event **create** (`ADDED`) and **update** (`UPDATED`) notifications are forwarded to the sink. An update is only forwarded when the event's `resourceVersion` changed. `[GA]`
3. Event **delete** notifications are **not** forwarded. Deletes occur only on TTL expiry by the cluster's event garbage collection and carry no new information. `[GA]`

### Namespace Scoping

4. The `WATCH_NAMESPACE` environment variable scopes the informer to a single namespace. When unset or empty, the Event Router watches events cluster-wide across all namespaces. `[GA]`

### Sinks

5. **`stdout`** — serializes each event to JSON and writes it to standard output. This is the sink used in OpenShift Logging so that Vector collects the events as container logs. `[GA]`
6. **`glog`** — the upstream default sink; serializes each event to JSON and emits it through glog. Present in source but not used by the product. `[UNSUPPORTED]`
7. **`http`** — sends events to an HTTP endpoint using RFC5424 (syslog-over-HTTP) framing, with buffering and overflow handling. Present in source but not used by the product. `[UNSUPPORTED]`
8. **`kafka`** — publishes events to a Kafka topic. Present in source but not used by the product. `[UNSUPPORTED]`

### Output Format

9. Each emitted record is an `EventData` JSON object with fields `verb` (`ADDED` or `UPDATED`), `event` (the current `v1.Event`), and, for updates, `old_event` (the prior `v1.Event`). `[GA]`

### Deployment

10. The Event Router is deployed manually as a single-replica `Deployment`. It performs no leader election and is not highly available; running more than one replica would duplicate events. `[GA]`
11. Deployment requires a `ServiceAccount`, a `ClusterRole` granting `get`, `watch`, and `list` on `events`, and a `ClusterRoleBinding`. Configuration is supplied via a `ConfigMap` mounting `config.json` at `/etc/eventrouter/`. `[GA]`
12. The Event Router should be deployed into an operations namespace (e.g. `openshift-logging`) so that its logs are collected as **infrastructure** log-type. The upstream sample manifests default to `kube-system`, which is also an infrastructure namespace. `[GA]`
13. The container image is distributed as `registry.redhat.io/openshift-logging/eventrouter-rhel8` and built from the `openshift/eventrouter` repository. It is not shipped as part of the cluster-logging-operator and must be deployed separately. `[GA]`

### Metrics

14. The Event Router exposes Prometheus metrics at `/metrics` on the address given by `--listen-address` (default `:8080`) when `enable-prometheus` is set (default `true`). An optional `/debug/pprof` handler is available when `enable-http-pprof` is enabled (default `false`). `[GA]`

### Downstream Processing

15. The Event Router only emits raw event JSON to stdout. Parsing and ViaQ shaping of these records (lifting the nested `event` object, deriving `@timestamp`, the `EventRouterLog` data model) is performed by the collector in the cluster-logging-operator — see `what/log-collection.md` and `what/log-forwarding.md`. `[GA]`

## Configuration Surface

| Field | Type | Default | Description |
|---|---|---|---|
| `sink` | enum | `glog` | Sink implementation: `stdout`, `glog`, `http`, `kafka`. OpenShift Logging uses `stdout`. |
| `kubeconfig` | string | `""` | Path to a kubeconfig. Empty uses in-cluster config. |
| `resync-interval` | duration | `30m` | Informer full-resync interval. |
| `enable-prometheus` | bool | `true` | Serve Prometheus metrics at `/metrics`. |
| `enable-http-pprof` | bool | `false` | Serve `/debug/pprof` handlers. |
| `httpSinkUrl` | string | — | Target URL for the `http` sink (required when `sink: http`). |
| `httpSinkBufferSize` | int | `1500` | Buffered events for the `http` sink. |
| `httpSinkDiscardMessages` | bool | `true` | Drop events when the `http` sink buffer overflows. |
| `kafkaBrokers` | []string | `["kafka:9092"]` | Broker list for the `kafka` sink. |
| `kafkaTopic` | string | `eventrouter` | Topic for the `kafka` sink. |
| `kafkaAsync` | bool | `true` | Asynchronous produce for the `kafka` sink. |
| `kafkaRetryMax` | int | `5` | Max produce retries for the `kafka` sink. |
| `WATCH_NAMESPACE` (env) | string | `""` (all) | Restrict the watch to a single namespace. |
| `KUBECONFIG` (env) | string | — | Overrides the `kubeconfig` config value. |
| `EVENTROUTER_CONFIG` (env) | string | — | Overrides the config file path (default `/etc/eventrouter/config.json`). |
| `--listen-address` (flag) | string | `:8080` | Address for the metrics/pprof HTTP server. |

## Constraints

- Single replica only. There is no leader election, so scaling beyond one replica duplicates forwarded events.
- Delete events (TTL expiry) are never forwarded; the router is a stream of created/updated events, not a persistent store.
- Requires manual deployment. The cluster-logging-operator does not create, reconcile, or manage the Event Router.
- The `ClusterRole` grants cluster-wide read on `events` even when `WATCH_NAMESPACE` restricts the actual watch scope.
- Only the `stdout` sink is supported in the product. The `glog`, `http`, and `kafka` sinks exist in source but are undocumented for OpenShift Logging and therefore unsupported.
