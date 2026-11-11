# Vector Improvement Investigation (LOG-10547)

Follow-up to the [LOG-10388 OTEL vs Vector
benchmark](../README.md): the benchmark compared native log collection
only — the OTEL side did not perform VIAQ normalization — so part of
Vector's observed cost is the VRL transformation pipeline. This folder
enumerates where that cost lives and what could be done about it.

- Jira: [LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)
  (sub-task of [LOG-10388](https://redhat.atlassian.net/browse/LOG-10388))
- Correctness bug found during the analysis:
  [LOG-10546](https://redhat.atlassian.net/browse/LOG-10546)
  (openshift.labels dedot never executes — see
  [label-dedotting.md](label-dedotting.md))

## Areas, in rough order of expected benefit

| Doc | Area | Status |
|---|---|---|
| [native-level-eval.md](native-level-eval.md) | Native Rust level evaluation | Benchmarked: 2.6× CPU win, gate cleared — decision needed ([LOG-10548](https://redhat.atlassian.net/browse/LOG-10548)) |
| [kubernetes-fields-suppression.md](kubernetes-fields-suppression.md) | Suppress unused kubernetes_logs annotation fields | Validated on live cluster: −16% CPU, −31% mem (fields only); −27% CPU, −43% mem with annotations also suppressed; closes pod_ip/pod_owner output leak |
| [label-dedotting.md](label-dedotting.md) | Dedot restructure + LOG-10546 fix | Approved, not yet implemented |
| [del-move-hygiene.md](del-move-hygiene.md) | `del()` move-hygiene in the copy-out | Identified |
| [internal-wrap-elimination.md](internal-wrap-elimination.md) | Eliminate the `_internal` wrap | Identified (larger redesign) |
| [remap-consolidation.md](remap-consolidation.md) | Merge chained remaps | Identified (smallest win) |

## Benchmark artifacts

The native level-eval benchmark lives in
[`level-eval-bench/`](level-eval-bench/) (corpus generator, configs,
harness, `RESULTS.md`).

The field-suppression, label-dedotting, and LOG-10546 fixes are planned
as a single CLO PR.
