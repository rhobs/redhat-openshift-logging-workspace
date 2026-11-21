# Eliminate the `_internal` wrap

From the [Vector improvements investigation](README.md)
([LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)). Larger
redesign; expected benefit: removes the wrap, the copy-out half of
`viaq_0`, and the `_internal` double-hold entirely.

## Option A: sources emit directly under `_internal`

`log_schema` keys accept dotted paths (`message_key =
"_internal.message"`), and annotator field mappings accept dotted
destinations. Hardcoded `.stream`/`.file` need small residual moves.

Caveat: `log_schema` is global — every component that consults it needs
auditing (blast radius across the whole topology).

## Option B: remove `_internal` entirely via per-log_type schema enforcement

- `only_fields` whitelist for container/journal (bounded VIAQ schema)
- An audit-API-schema whitelist for k8s audit (semantic change: drops
  undocumented upstream audit fields)
- A small blacklist of processing intermediates for receivers
  (open-ended payloads)

Caveats: changes merge-collision semantics (structured JSON merged at
root can overwrite processing fields) and requires a product decision on
audit field semantics.
