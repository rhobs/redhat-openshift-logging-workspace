# Label dedot restructure + LOG-10546 fix

From the [Vector improvements investigation](README.md)
([LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)). Expected
benefit: avoid a clone of the whole `kubernetes` subtree and the
double-hold of the originals under `_internal`.

## Problem

Current pattern builds `dedot_labels` alongside the originals, clones
the whole `kubernetes` subtree to root
(`.kubernetes = ._internal.kubernetes`), then overwrites the
just-copied labels with the dedotted map; originals stay alive under
`_internal` until the sink strips it.

## Bug: LOG-10546 — openshift.labels dedot never executes

[LOG-10546](https://redhat.atlassian.net/browse/LOG-10546): the
`openshift.labels` dedot in `viaq_0` is dead code — the consumer (line
~726) runs before the producer (~800-804) within the same remap, and the
`dedot_labels` map initializer sits inside the `for_each` loop so only
the last label would survive even if it ran.

## Plan

- In-place dedot after `del`-moving the `kubernetes` subtree to root:
  eliminates the clone, the throwaway map, and the double-hold.
- Fix the openshift.labels dedot (LOG-10546). Output behavior change:
  openshift label keys that currently ship dotted will ship dedotted,
  per the datamodel intent.

This is part of the approved CLO PR together with the
[field suppression](kubernetes-fields-suppression.md) work.
