# Native Rust level evaluation (LOG-10548)

Tracking: [LOG-10548](https://redhat.atlassian.net/browse/LOG-10548)
(sub-task of [LOG-10388](https://redhat.atlassian.net/browse/LOG-10388),
related to [LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)).

Replace the five-stage VRL log-level detection cascade (logfmt → klog →
grok → structured patterns → earliest-keyword regex) with a native Rust
transform so the policy stays in CLO config as data and only the engine
is Rust.

## Why VRL is expensive here

The regexes themselves are compiled once and identical either way. The
VRL-specific per-event costs:

- AST node dispatch and runtime type checks per event
- Intermediate map allocations: `parse_logfmt`/`parse_groks` build a full
  map of every key in the message to extract one field
- Error-path machinery on the happy path; the fallback cascade re-reads
  the whole message once per failed attempt (up to 5 passes)

## Prototype design

Generic `extract_pattern` transform on vector branch
`bench/log-10547-extract-pattern` (throwaway): an ordered (pattern,
value) rule list evaluated against a field; the first match sets the
target field. Configured with 46 rules equivalent to the CLO's
five-stage level-detection VRL (attempts 4/5 verbatim; klog from vrl
`REGEX_KLOG`; grok from `LOGLEVEL`/`TIMESTAMP_ISO8601`; logfmt as the
`level=` token equivalent).

Two field modes, discriminated at config load:

- **Template** (`field = "{{ message }}"`) — rendered per event (owned)
- **Field path** (`field = "message"`) — parsed once at startup via
  `parse_target_path`, read by reference per event, zero allocation

All patterns and the path are compiled/parsed once in `build()` at
startup; nothing per-event except the match itself.

## Benchmark

See [`level-eval-bench/`](level-eval-bench/) — corpus generator, both
transform configs, null baseline, harness, and `RESULTS.md`. Method:
file source → transform → file sink, 20,000-line mixed corpus
(klog=40%, json=30%, plain=15%, keyword=10%, logfmt=4%, grok=1%), 3
runs per side, CPU from cgroup v2 `cpu.stat`, memory from
`memory.peak`, null-baseline subtracted.

## Results (field-path mode)

| Side | Mean CPU | Transform-attributable | Per event |
|---|---|---|---|
| null (no transform) | 447.7 ms | — | — |
| VRL remap | 739.1 ms | 291.5 ms | 14.6 µs |
| extract_pattern | 559.8 ms | 112.2 ms | 5.6 µs |

**~2.6× CPU win** (14.6 → 5.6 µs/event) — clears the pre-agreed 2×
productionization gate. At 40k events/s per node, saves ~0.36 core of
transform CPU against the ~3-core effective cap from LOG-10183.
Template mode measured only 1.9×; per-event template rendering cost
~3.7 µs/event.

**Equivalence:** PASS — `level` identical for all 20,000 events between
the VRL program and the ordered-rule config. A pre-build simulation
caught three rule-fidelity bugs before any container run (missing
fatal/severe/emerg grok variants; `warning` collapsing to `warn`;
`WARN(?:ING)?` matching bare WARN first).

**Peak RSS:** null ~171 MB, VRL ~197 MB, extract_pattern ~215 MB. The
~+18 MB native-vs-VRL delta is unresolved. Two theories tested and
falsified: per-event template rendering (path mode removed it with no
RSS change) and lazy-DFA cache growth (a 256 KB `dfa_size_limit` cap
left peak RSS unchanged while costing CPU — 7.1 vs 5.6 µs/event, ratio
2.6× → 2.0× — so the cap was reverted). The VRL side compiles its own
grok-based regexes with the same cache defaults, so the delta likely
lives in the per-regex NFA/one-pass programs, per-thread pool
duplication, or measurement noise. Remaining lever: merge rule groups
into single alternation regexes (~46 → ~20 rules), shrinking every
per-regex structure at once.

## Known semantic difference

VRL attempt 5 picks the level keyword appearing *earliest* in the
message; ordered rules pick by severity priority. Messages containing
multiple level keywords would classify differently.

## Decision needed

The 2× gate is cleared. Productionization carries ongoing cost: ~150
lines of transform code rebased across every vector-rhel9 rebase and
CVE-audited, plus tests and docs — versus the level policy staying in
CLO config. Remaining optimization headroom: keyword-rule alternation
merge (~46 → ~20 regexes, likely also the RSS lever), rule reordering
by observed hit frequency.
