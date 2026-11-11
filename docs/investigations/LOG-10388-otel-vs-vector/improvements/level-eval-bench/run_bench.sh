#!/usr/bin/env bash
# LOG-10547 benchmark: VRL remap vs native extract_pattern transform.
# Usage: ./run_bench.sh [--corpus-only]
# Env:
#   TOTAL   total lines (default 20000)
#   MIX     category mix, comma-separated cat=pct (default below)
#   REPEATS runs per side (default 3)
#   IMAGE   vector image (default localhost/vector-level-bench:latest)
set -euo pipefail
cd "$(dirname "$0")"

TOTAL=${TOTAL:-20000}
MIX=${MIX:-klog=40,json=30,plain=15,keyword=10,logfmt=4,grok=1}
REPEATS=${REPEATS:-3}
IMAGE=${IMAGE:-localhost/vector-level-bench:latest}

mkdir -p corpus out
python3 gen_corpus.py --out corpus/input.log --total "$TOTAL" --mix "$MIX"

[[ "${1:-}" == "--corpus-only" ]] && exit 0

run_side() {
    local side=$1 i
    for i in $(seq "$REPEATS"); do
        local dir="run-$side-$i"
        rm -rf "$dir"; mkdir -p "$dir"
        echo "=== $side run $i ==="
        podman run --rm \
            -v "$PWD/corpus:/bench/corpus:Z" \
            -v "$PWD/$dir:/bench/out:Z" \
            -v "$PWD/vector-$side.toml:/bench/config.toml:Z" \
            "$IMAGE" sh -c '
                mkdir -p /var/lib/vector/bench
                timeout --signal=TERM 45 vector --config /bench/config.toml
                echo "--- cgroup ---"
                grep -E "usage_usec|user_usec|system_usec" /sys/fs/cgroup/cpu.stat
                cat /sys/fs/cgroup/memory.peak 2>/dev/null || true
            ' | tee "$dir/stats.txt"
        local lines
        lines=$(wc -l < "$dir/result.log")
        if [[ "$lines" != "$TOTAL" ]]; then
            echo "INCOMPLETE: $side run $i wrote $lines/$TOTAL events; increase timeout"
            exit 1
        fi
    done
}

run_side null
run_side vrl
run_side extract

echo
echo "=== equivalence check ==="
for f in run-null-1/result.log run-vrl-1/result.log run-extract-1/result.log; do
    [[ -s "$f" ]] || { echo "FAIL: $f missing or empty"; exit 1; }
done
if diff <(jq -c '{message: .message, level: .level}' run-vrl-1/result.log) \
         <(jq -c '{message: .message, level: .level}' run-extract-1/result.log) > /dev/null; then
    echo "PASS: level output identical across $(wc -l < run-vrl-1/result.log) events"
else
    echo "FAIL: outputs differ; inspect with:"
    echo "  diff <(jq -c '{m:.message,l:.level}' run-vrl-1/result.log) <(jq -c '{m:.message,l:.level}' run-extract-1/result.log) | head -40"
    exit 1
fi
