# Merge chained remap transforms

From the [Vector improvements investigation](README.md)
([LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)). Smallest
win of the set; not currently planned.

## Problem

An event traverses ~4 remap transforms (meta → viaq → filters → output).
Each hop is a channel/task boundary (~1–3µs).

## Assessment

Merging saves ~5–15% of transform cost but loses per-transform error
handling and metrics semantics. Recommend revisiting only after the
larger items land.
