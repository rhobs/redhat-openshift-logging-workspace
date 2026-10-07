# LOG-8336 — Throughput & latency impact of sink acknowledgements (journald collection)

Follow-up measurement for [LOG-8336](https://redhat.atlassian.net/browse/LOG-8336). The original
investigation ([Clee2691/clo_investigations @ LOG-8336](https://github.com/Clee2691/clo_investigations/blob/LOG-8336/reports/LOG-8336-journal-loss-investigation.md))
established that stock CLO 6.6 loses **5–10% of journal logs** on collector restart under backpressure,
and that enabling Vector sink `acknowledgements.enabled = true` prevents it.

**Question answered here:** what is the throughput/latency *cost* of enabling acknowledgements?

## TL;DR

- **Steady state (sink keeping up): acks are essentially free** — ~0% throughput change, latency within
  noise (~1 ms), ~equal CPU, small memory increase (~12 MB).
- **Under backpressure: no throughput or latency difference either** — with or without acks the collector
  fills the ~128 MiB disk buffer at full source rate in ~20–50 s, then blocks the journald source;
  delivered throughput is gated by Loki, not by the ack setting.
- The only thing acks change is **data durability** (the small in-flight window lost on restart —
  LOG-8336's 5–10% loss), which is a correctness property, not a performance one.
- Practical implication: enabling the LOG-8336 fix has negligible performance cost.

## Environment

- Deployment tooling: `cluster-logging-operator` **master** `hack/manifests` (Garage S3, kustomize, log tooling).
- Operators (released): **CLO 6.6.1**, **Loki 6.6.1**, COO 1.5.2.
- Storage: in-cluster **Garage** (S3-compatible); LokiStack `1x.demo` (single ingester).
- Collection path: custom `infrastructure` input restricted to `sources: [node]` (journald only) →
  `lokiStack` output, `deliveryMode: AtLeastOnce` (256 MB disk buffer, `when_full = block`).
- Load: privileged `journal-injector` DaemonSet running parallel `logger` workers into the host journal.
- Metrics: cluster monitoring (thanos-querier) scraping Vector internal metrics, scoped to the collector
  pod on the injector's node.

### Stock-config observation (confirms LOG-8336)

Stock CLO 6.6 `AtLeastOnce` generates a loki sink with a **256 MB disk buffer** but **no
`acknowledgements` block** — end-to-end acks are OFF by default. See [`configs/vector-acks-off.toml`](configs/vector-acks-off.toml).

## Results

### Steady state, ~1300 ev/s, sink keeping up

| Metric | Acks OFF | Acks ON | Δ |
|---|---|---|---|
| Sink delivered throughput | 1304 ev/s | 1309 ev/s | ~0% |
| Journal read rate | 1303.8 ev/s | 1302.9 ev/s | ~0% |
| Loki request RTT (avg) | 34.9 ms | 36.2 ms | +1.3 ms (~4%) |
| Buffer send duration (avg) | 1.60 ms | 2.12 ms | +0.5 ms |
| In-flight requests (avg) | 0.5 | 0.5 | 0 |
| Collector CPU | 0.431 cores | 0.423 cores | ~0% |
| Collector memory (working set) | 94 MB | 106 MB | +12 MB (~13%) |

Raw: [`results/result-acks-off.txt`](results/result-acks-off.txt), [`results/result-acks-on.txt`](results/result-acks-on.txt).

### Backpressure (Loki ingester scaled to 0), disk-buffer fill from empty

| t (s) | Acks OFF — buffer events | Acks ON — buffer events |
|---|---|---|
| 0 | 0 | 0 |
| 18 | 42,289 | 70,319 |
| 36 | 67,996 | 70,319 |
| 54 | 69,520 (full) | 70,319 (full) |
| 72+ | 69,520 — source blocked | 70,319 — source blocked |

Both modes fill the ~128 MiB disk buffer to capacity, then `when_full=block` stalls the journald source;
delivered = 0 throughout. Raw: [`results/result-bp-off-clean.txt`](results/result-bp-off-clean.txt),
[`results/result-bp-on-clean.txt`](results/result-bp-on-clean.txt).

> Note: the journald source read rate tops out at ~1300 ev/s per node regardless of injector worker count
> — the ceiling is **systemd journald rate-limiting**, not Vector or the injector.

## Reproduce

Prereqs: `oc` logged in as cluster-admin, an AWS/ROSA OpenShift cluster, and the
`cluster-logging-operator` master `hack/manifests` checked out (`$CLO/hack/manifests`).

```bash
export CLO=/path/to/cluster-logging-operator            # master checkout
export TARGET_NODE=<a worker node>                       # e.g. ip-10-0-1-18.ec2.internal
DEST=docs/investigations/LOG-8336-journal-acks-perf

# 1. Operators (CLO + Loki 6.6 + COO) and Garage S3. (Loki sub is already stable-6.6;
#    set the CLO subscription channel to stable-6.6 if it is pinned lower.)
oc apply -k $CLO/hack/manifests/observability-operators/
oc wait pod -n openshift-logging -l app.kubernetes.io/name=garage --for=condition=Ready --timeout=180s

# 2. LokiStack (Garage-backed)
oc apply -k $CLO/hack/manifests/receivers/lokistack/

# 3. Collector RBAC + journald-only ClusterLogForwarder
oc apply -f $DEST/manifests/rbac.yaml
oc apply -f $DEST/manifests/clf-journal.yaml

# 4. Journal injector (privileged)
oc create sa journal-injector -n openshift-logging
oc apply -f $DEST/manifests/injector-scc-rb.yaml      # grants privileged SCC via RoleBinding
sed "s/PLACEHOLDER_NODE/$TARGET_NODE/" $DEST/manifests/journal-injector.yaml | oc apply -f -

# 5. Baseline (acks OFF = stock default) — let it warm up ~4 min first
bash $DEST/scripts/bench-measure.sh "acks off"

# 6. Enable acks: Unmanaged -> edit configmap -> reload
oc patch clusterlogforwarder collector -n openshift-logging --type merge \
  -p '{"spec":{"managementState":"Unmanaged"}}'
cd $DEST/scripts && python3 build-cfg.py acks_on on && cd -   # or hand-edit the configmap
# apply the acks-on vector.toml to the collector-config configmap, then:
oc delete pod -n openshift-logging -l app.kubernetes.io/instance=collector
bash $DEST/scripts/bench-measure.sh "acks on"                 # warm up ~4 min, then measure

# 7. Backpressure variant: scale loki-operator then ingester to 0, use build-cfg.py to get a
#    fresh-buffer sink id per phase, restart the collector, and sample the fill:
bash $DEST/scripts/bench-sample.sh "acks off + backpressure"  # SINK=<renamed id> env override
```

Restore: return the CLF to `Managed` (regenerates the stock config), scale the loki-operator and
ingester back to 1, delete the `journal-injector` DaemonSet.

## Files

- `manifests/` — CLF (journald-only), collector RBAC, injector DaemonSet + privileged SCC binding.
- `scripts/` — `bench-measure.sh` (steady-state snapshot), `bench-sample.sh` (time-series fill/drain),
  `build-cfg.py` (derive acks-on / fresh-buffer configs).
- `configs/` — captured stock baseline Vector config and the acks-enabled variant.
- `results/` — raw measurement output.
