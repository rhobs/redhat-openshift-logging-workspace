# LOG-10388 — OTEL Collector vs Vector for application log collection

Benchmark comparing the Red Hat Build of OpenTelemetry Collector (v0.158.0, operator
`opentelemetry-product` stable) against the RHOL Vector collector (CLO release-6.7 +
PR #3569 rotation fix) for application-log collection into LokiStack.

- Spec: [`docs/superpowers/specs/2026-10-08-otel-vs-vector-perf-comparison-design.md`](../../superpowers/specs/2026-10-08-otel-vs-vector-perf-comparison-design.md)
- Jira: LOG-10388
- Dates: 2026-11-05 → 2026-11-06; environment: ROSA/HCP, 2× 4-CPU/16Gi workers,
  LokiStack 1x.demo, goloader synthetic payload of **512 bytes per log event**
  (`--synthetic-payload-size=512 --log-format=default`, identical for both
  collectors; on-disk lines carry ~50–60B of CRI prefix overhead on top), 600s
  steady windows, goloader pacing (verified exact per-pod). Raw rows:
  `results/summary.csv`; per-run logs and sample CSVs alongside.

## Results — Phase 1 throughput ladder (single pipeline, per-pod max)

| rate (lines/s) | Vector loss | OTEL loss | Vector CPU | OTEL CPU | Vector mem | OTEL mem |
|---|---|---|---|---|---|---|
| 2500  | 0.17%  | −0.03% | 375m  | 31m  | 471Mi  | 67Mi  |
| 5000  | 0.15%  | −0.02% | 728m  | 60m  | 777Mi  | 70Mi  |
| 10000 | 0.00%  | 0.14%  | 837m  | 63m  | 1105Mi | 73Mi  |
| 20000 | 0.17%  | −0.03% | 1761m | 132m | 1132Mi | 86Mi  |
| 40000 | **29.11%** | **−0.02%** | 2494m | 282m | 961Mi  | 100Mi |

(Vector multi-pipeline CLF at 40k/s: 53.13% loss, mem at the 2048Mi limit.)

## Results — Phase 2 fan-in (20k/s total, 5/10/20/40 source containers) + fd release

| containers | Vector loss / CPU / mem | OTEL loss / CPU / mem |
|---|---|---|
| 5  | 0.13% / 2027m / 526Mi | 0.07% / 166m / 90Mi  |
| 10 | 0.17% / 1856m / 454Mi | 0.01% / 143m / 103Mi |
| 20 | 0.14% / 1789m / 455Mi | −0.04% / 149m / 97Mi |
| 40 | 0.12% / 1604m / 449Mi | 0.00% / 150m / 93Mi  |

fd release after generator scale-down: Vector 18s, OTEL 18s (steady-state ~50 fds at
40 containers → ~10 after release; `results/fd_release_*.csv`).

## Results — node-label suppression experiment (Vector, 20k/s single pipeline)

CLO bench patch (worktree commit `5f25d337a`): set
`kubernetes_logs` `node_annotation_fields.node_labels = ""` so node labels are never
attached to events. Rationale: the VIAQ normalize filter already runs
`del(.kubernetes.node_labels)` on every event — attaching them is pure overhead.
(Same generator shape and CLF as the Phase-1 20k baseline: 4 pods × 5000/s, one
application input → one pipeline → one lokiStack output.)

| config | loss | cpu_med | mem_med |
|---|---|---|---|
| baseline (`p1_vector_20000`) | 0.17% | 1761m | 1132Mi |
| node labels suppressed (`p1_vector-nolabels_20000`) | 0.08% | 1436m | 511Mi |

Suppressing node labels cuts Vector's memory **55%** and CPU **19%** at 20k/s — but
Vector still runs ~10× OTEL's CPU (1436m vs 132m) at this rate, so the node-label
waste explains only part of the gap; the remainder is Vector's per-event pipeline
(enrichment, VIAQ remap transforms, loki sink) vs OTEL's lean file_log → batch → OTLP.

## Headline findings

1. **Delivery**: both collectors deliver ≈100% of lines from 2.5k to 20k lines/s.
   At 40k/s Vector collapses (29% single-pipeline / 53% multi-pipeline loss) while
   OTEL still delivers 100% at ~1/9th the CPU.
2. **Cost**: OTEL uses ~6–12× less CPU and ~7–15× less memory than Vector per line
   at every rate. (Vector's CLF pipeline does more per line — enrichment, transforms,
   multiple sinks — but the delta is far larger than feature parity explains.)
3. **Fan-in**: both scale flat from 5→40 source containers; fds release promptly (18s).
4. **Caveats**:
   - CPU/mem are per-pod maxima (same methodology both collectors); at ≥10k/s the load
     spreads across both workers' collector pods.
   - Loki 1x.demo was distressed during Vector's 40k runs (429s, ingester 500s,
     WAL 20+Gi) but NOT during OTEL's 40k run — part of Vector's 40k "loss" is
     Loki-side. Even so, Vector's own source ceiling (~28k/s, consistent with
     LOG-10183) and multi-pipeline memory exhaustion are collector-side and real;
     OTEL crossed 40k/s with no collector-side stress at all (282m CPU, 100Mi mem).
   - OTEL `file_log` skips `.gz`-rotated files; Vector (with PR #3569) reads them.
   - Vector numbers come from cluster 2, OTEL from cluster 3 (same shape/config).

## Changes needed to run OTEL (deployment deltas vs the naive CR)

Everything is in `otelc.yaml` (header comments) + `otelc-rbac.yaml`; the hard-won list:

1. **v1beta1 API with structured config** — the webhook rejects string configs
   (`cannot unmarshal string into ... v1beta1.Config`); v1alpha1 is deprecated.
2. **SCC**: `oc adm policy add-scc-to-user logging-scc -z otel-collector-collector
   -n openshift-opentelemetry-collector` — `hostmount-anyuid` is insufficient;
   without `logging-scc` the DS pods are Forbidden (hostPath + `spc_t`).
3. **Pod securityContext**: `runAsUser: 0` + `seLinuxOptions.type: spc_t` (+
   hostPath volume `/var/log/pods`) — `/var/log/pods` is `drwxr-x--- root:root`;
   the Vector DS uses the same SELinux type.
4. **Write RBAC**: `oc adm policy add-cluster-role-to-user
   cluster-logging-write-application-logs -z otel-collector-collector ...` or the
   gateway 403s.
5. **Label mapping**: LokiStack's OTLP endpoint maps ONLY `k8s.*` resource attributes
   to labels (`k8s.namespace.name` → `k8s_namespace_name`). Using `kubernetes.*`
   yields zero labels → every entry is 400-rejected ("at least one label pair is
   required per stream") and dropped. The stanza path-regex must therefore move
   parsed fields to `resource["k8s.*"]`.
6. **Path regex UID width**: `[a-f0-9-]{32,36}` — some pods have 32-hex UIDs; a parse
   failure sends the entry unlabeled → Loki 400 → dropped.
7. **Resilience processors** (GA per RHOSDT specs, documented guidance): without
   `memory_limiter` + `batch`, a backend outage OOM-kills the collector and drops
   batches. Config ships both (limit 1800Mi / spike 300Mi; batch 512/1s).
8. **k8s_attributes** (GA) needs pods get/list/watch cluster-wide (`otelc-rbac.yaml`)
   for metadata enrichment parity with Vector's `kubernetes_logs`.
9. **Exporter**: `otlp_http/loki` → LokiStack gateway
   `/api/logs/v1/application/otlp` with service-ca `ca_file` + `bearertokenauth`
   (SA token) — component names use the 0.158 non-deprecated spellings
   (`file_log`, `otlp_http/...`, `k8s_attributes`).

Bench-harness deltas for OTEL runs (`bench-lib.sh otel_init()`): loki label
`k8s_namespace_name`; collector pods `otel-collector-collector-*` in
`openshift-opentelemetry-collector`; drain gate via the `:8888` self-metrics
counter `otelcol_receiver_accepted_log_records` (renders in scientific notation
above 1e6 — normalize to int before bash arithmetic).

## Instrumentation notes (apply to any rerun)

- emitted = NOMINAL (npods × perpod × steady): goloader paces exactly; seq-counter
  snapshots take 60–90s and are read after t_end while generators still run, so
  seq deltas overcount wildly at high rates (20k run showed +123% "off" purely from
  post-window lines). The Loki `[t_start,t_end]` window query is ground truth.
- A `delivered=0` at finalize time can be Loki index lag — always re-query after
  drain (the finalize step's 0-guard exists for this; it corrected the 40k row from
  100% "loss" to −0.02%).
- LokiStack gateway auth layer rejects some LogQL regexes: `{...=~"loadgen.*"}` →
  400; use explicit alternation.
- Negative loss (delivered slightly > nominal) = window edge effects, not real.

## Contents

- `bench-lib.sh` — measurement library (mode-aware: vector / otel via `otel_init`)
- `run-phase1.sh`, `run-phase1b.sh` (vector single/multi), `run-phase1-otel.sh`,
  `run-phase2.sh <vector|otel> <rate>` — ladder + fan-in/fd drivers
- `otelc.yaml`, `otelc-rbac.yaml` — OTEL CR (v1beta1) + k8s_attributes RBAC
- `clf-vector.yaml`, `clf-vector-multi.yaml` — Vector CLFs + bench RBAC
- `generator.yaml`, `generator-multi.yaml`, `lokistack.yaml`, `querycli.yaml`
- `results/` — summary.csv, per-run sample CSVs, window files, logs, fd-release CSVs
