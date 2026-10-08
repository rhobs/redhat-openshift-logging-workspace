# OTEL Collector vs Vector — Performance Benchmark `[PLANNED]`

Performance benchmark comparing the Red Hat build of the OpenTelemetry Collector against Vector for application log collection on OpenShift. Produces raw comparison data for the team to make an informed decision on the OTEL collector migration. Related: [OTEL Collector Migration](otel-collector-migration.md).

## Behavioral Rules

### Scope

1. The benchmark covers **application logs only** — container stdout, unstructured text, forwarded to LokiStack. `[PLANNED]`
2. Journal logs, audit logs, structured JSON parsing, latency measurement, backpressure/recovery testing, and multi-tenant configurations are out of scope. `[PLANNED]`

### Test Environment

3. Tests run on a dedicated OCP cluster (or dedicated worker nodes) with minimum 3 workers to eliminate noisy-neighbor effects. `[PLANNED]`
4. Vector is deployed via CLO using ClusterLogForwarder CR with default resource limits. `[PLANNED]`
5. OTEL collector is deployed via the OTEL Operator using OpenTelemetryCollector CR in DaemonSet mode, using the Red Hat build, with the same resource limits CLO applies to Vector. `[PLANNED]`
6. OTEL collector pipeline: filelog receiver → k8s_attributes processor → otlp/loki exporter → LokiStack. `[PLANNED]`
7. LokiStack is torn down and redeployed between Vector and OTEL collector runs to avoid residual state. `[PLANNED]`

### Log Generation

8. The log generator is [cluster-logging-load-client](https://github.com/ViaQ/cluster-logging-load-client). `[PLANNED]`
9. Log format: unstructured text (`--log-format=default`), 512-byte log lines (`--synthetic-payload-size=512`). `[PLANNED]`
10. Generator output is stdout — logs flow through CRI-O → log file → collector → Loki (the real pipeline). `[PLANNED]`
11. Before each benchmark run, a validation step confirms the generator can sustain the target rate. `[PLANNED]`

### Test Scenarios

12. **Phase 1 — Ceiling test:** Deploy 1 container, incrementally increase `--logs-per-second` until collector saturates (log loss or resource limit hit). Record maximum sustainable rate (**R_max**) for each collector. `[PLANNED]`
13. **Phase 2 — Fan-in scalability:** Take the lower R_max of the two collectors as total target rate. Distribute evenly across 5, 10, 20, 40 containers. Record all metrics at each step. `[PLANNED]`
14. **File descriptor release test:** At 40 containers, after steady state, terminate all generator pods and monitor file descriptor count to verify release. `[PLANNED]`

### Test Run Parameters

15. Each test run sustains steady state for minimum 10 minutes, with a 2–3 minute warm-up period excluded from measurements. `[PLANNED]`
16. Each scenario is repeated 3 times. Results are reported as median with min/max range. `[PLANNED]`

### Metrics

17. **Throughput metrics:** logs ingested per second, logs delivered per second, bytes per second, log loss rate. `[PLANNED]`
18. **Resource metrics:** CPU usage (cores), memory usage (RSS), disk I/O (read/write), network I/O (receive/transmit). Sampled every 15 seconds via Prometheus. `[PLANNED]`
19. **File descriptor metrics:** open file descriptor count over time, release time after container termination. `[PLANNED]`

### Reporting

20. Results are presented as comparison tables per scenario — no pass/fail thresholds. The team interprets the data. `[PLANNED]`

### Reproducibility

21. All manifests (generator, collector configs, LokiStack CR) are committed to a repo. Exact image versions, OCP version, and node hardware specs are documented. `[PLANNED]`

## Design Spec

Full methodology and execution details: [`docs/superpowers/specs/2026-10-08-otel-vs-vector-perf-comparison-design.md`](../../../docs/superpowers/specs/2026-10-08-otel-vs-vector-perf-comparison-design.md)
