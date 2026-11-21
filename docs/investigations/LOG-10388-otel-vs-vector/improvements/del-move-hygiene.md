# `del()` move-hygiene in the VIAQ copy-out

From the [Vector improvements investigation](README.md)
([LOG-10547](https://redhat.atlassian.net/browse/LOG-10547)). Expected
benefit: cuts in-flight event memory ~30–50% where applicable.

## Problem

`.x = ._internal.x` copies leave both copies alive until the sink's
`except_fields` strips `_internal` — across all downstream buffers
including the sink's.

## Plan

Replace copies with moves: `.x = del(._internal.x)` frees each original
as it moves. Must verify nothing downstream reads the moved field —
e.g. the kafka topic template reads
`_internal.output_kafka_receiver_topic`, which must stay a plain copy
(or the template must read the new location).
