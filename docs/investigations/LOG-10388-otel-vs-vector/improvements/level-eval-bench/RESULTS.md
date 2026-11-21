# Level-eval benchmark results: VRL vs native extract_pattern (LOG-10547)

Date: 2026-11-09. Tracking: LOG-10547 (parent LOG-10388).

## Setup

- Image built from the workspace vector fork, branch
  `bench/log-10547-extract-pattern` (commit 73bf3a1119), via
  `podman build -f Dockerfile --build-arg FEATURES=ocp-logging-devel,transforms-extract_pattern`.
- New throwaway transform `extract_pattern`: ordered (pattern, value) rule
  list evaluated against a templated field; first match sets the target
  field. Configured with 46 rules equivalent to the CLO's five-stage
  level-detection VRL (attempts 4/5 patterns verbatim; klog from vrl's
  `REGEX_KLOG`; grok from `LOGLEVEL`/`TIMESTAMP_ISO8601`; logfmt as the
  `level=` token equivalent; `warning` preserved as `warning`, not `warn`).
- Corpus: 20,000 lines, mix klog=40%, json=30%, plain=15%, keyword=10%,
  logfmt=4%, grok=1% (valid klog dates — parse_klog validates them).
- Pipeline: file source -> transform -> file sink (json), 45s timeout per
  run, 3 runs per side plus a no-transform null baseline. CPU from cgroup
  v2 `cpu.stat` (usage_usec), memory from `memory.peak`.

## Results

Two rounds: the initial run rendered `field = "{{ message }}"` per event
(template mode); after it, `field` was switched to plain path mode
(`field = "message"` — parsed once at startup, read by reference per
event, zero allocation). Path mode is the current state of the branch.

### Field-path mode (current)

| Side | Mean CPU | Transform-attributable | Per event |
|---|---|---|---|
| null (no transform) | 447.7 ms | — | — |
| VRL remap | 739.1 ms | 291.5 ms | 14.6 µs |
| extract_pattern | 559.8 ms | 112.2 ms | 5.6 µs |

**CPU: native Rust is ~2.6× faster than VRL for the same logic**
(14.6 → 5.6 µs/event at this mix) — clears the 2× productionization
gate. At the LOG-10388 reference rate of 40k events/s per node, that
saves ~0.36 core of transform CPU — meaningful against the ~3-core
effective cap from LOG-10183.

Peak RSS: null ~171 MB, VRL ~197 MB, extract_pattern ~215 MB. The native
side still shows ~+18 MB vs VRL. Two theories tested and falsified:
per-event template rendering (path mode removed it with no RSS change)
and lazy-DFA cache growth (a 256 KB `dfa_size_limit` cap left peak RSS
unchanged at ~211 MB while *costing* CPU — 7.1 vs 5.6 µs/event, ratio
2.6× → 2.0× — so the cap was reverted). The VRL side compiles its own
grok-based regexes with the same cache defaults, so the delta likely
lives in the per-regex NFA/one-pass programs or per-thread pool
duplication, or is simply measurement noise. Remaining lever if the
delta matters: reduce the rule count by merging rule groups into single
alternation regexes (~46 → ~20), which shrinks every per-regex
structure at once.

### Template mode (superseded, kept for reference)

| Side | Mean CPU | Transform-attributable | Per event |
|---|---|---|---|
| null (no transform) | 402.7 ms | — | — |
| VRL remap | 759.3 ms | 356.6 ms | 17.8 µs |
| extract_pattern | 588.5 ms | 185.8 ms | 9.3 µs |

~1.9× CPU win, below the gate. Per-event template rendering of `field`
accounted for ~3.7 µs/event of native-side overhead (9.3 → 5.6).

## Equivalence

PASS: the `level` field was identical for all 20,000 events between the
VRL program and the ordered-rule config. A pre-build Python simulation of
both sides over the same corpus also reported 0/20000 differences and
caught three rule-fidelity bugs before any container run (missing
`fatal`/`severe`/`emerg` grok variants; `warning` collapsing to `warn`;
`WARN(?:ING)?` matching bare `WARN` first).

Known semantic difference (not exercised by this corpus): VRL attempt 5
picks the level keyword appearing earliest in the message; ordered rules
pick by severity priority. Messages containing multiple level keywords
would classify differently.

## Caveats

- Field-path mode clears the 2× gate at 2.6×; per-side spread across 3
  runs is ±5-10%, so the true ratio is roughly 2.3–2.9×.
- Single mix tested; no oversized-line category in the default mix.
- Container-level measurement includes 45s of idle tail, identical on all
  sides; the null-baseline subtraction removes it from the comparison.

## Optimization headroom (untested)

1. Merge the ten attempt-5 keyword rules into one alternation regex with
   a value map (halves the fallback-path regex count and its DFA caches).
2. Reorder rules by observed hit frequency (klog first for infra-heavy
   nodes) — rules short-circuit on first match.
3. Cap `dfa_size_limit` per regex if the ~+18 MB peak RSS matters.

## Artifacts

- `gen_corpus.py`, `vector-{null,vrl,extract}.toml`, `run_bench.sh`
- `run-*/stats.txt`, `run-*/result.log`
- Transform source: `vector/src/transforms/extract_pattern.rs` on branch
  `bench/log-10547-extract-pattern` (throwaway, not for release)
