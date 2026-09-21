#!/usr/bin/env python3
"""Derive a Vector config from the captured stock baseline (../configs/vector-acks-off.toml).

Usage: build-cfg.py <new-sink-id> <on|off>
  - <new-sink-id>: renames the loki sink table (and thus its on-disk buffer id), giving a
    fresh empty disk buffer -- used to capture backpressure fill curves from an empty buffer
    without needing node access to clear /var/lib/vector.
  - on|off: whether to add `acknowledgements.enabled = true` to the loki sink.

Writes vector-<id>.toml and cm-<id>.json (a merge patch for the collector-config configmap)
to the current directory.
"""
import sys, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "..", "configs", "vector-acks-off.toml")

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    newid = sys.argv[1]
    acks = sys.argv[2] == "on"

    toml = open(BASE).read()
    # Rename ONLY the sink tables (prefix "sinks.") -> fresh disk buffer id.
    # The upstream transform reference (a quoted string without the "sinks." prefix) is untouched.
    toml = toml.replace("sinks.output_lokistack_output_infrastructure", "sinks." + newid)

    if acks:
        out, done = [], False
        for line in toml.splitlines(keepends=True):
            out.append(line)
            if not done and line.strip() == 'out_of_order_action = "accept"':
                out.append("\n[sinks.%s.acknowledgements]\nenabled = true\n" % newid)
                done = True
        toml = "".join(out)

    open("vector-%s.toml" % newid, "w").write(toml)
    open("cm-%s.json" % newid, "w").write(json.dumps({"data": {"vector.toml": toml}}))
    print("built vector-%s.toml (acks=%s)" % (newid, acks))

if __name__ == "__main__":
    main()
