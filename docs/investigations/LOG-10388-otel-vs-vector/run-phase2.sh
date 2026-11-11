#!/bin/bash
# Phase 2 — Fan-in scalability + fd release test (LOG-10388)
# Usage: ./run-phase2.sh <collector-label> <total-rate>
set -uo pipefail
cd "$(dirname "$0")"
source ./bench-lib.sh

COLLECTOR="${1:?collector label (vector|otel)}"
[[ "$COLLECTOR" == "otel" ]] && otel_init   # k8s_* labels, otel pod selection
RMAX="${2:?total target rate (lower R_max of the two collectors)}"
STEADY=600
LOSS_THRESHOLD=1.0

[[ -f "$RESULTDIR/summary.csv" ]] || echo "tag,collector,rate,n_pods,steady_s,emitted,delivered,loss_pct,cpu_med_m,cpumax_m,mem_med_mi,mem_max_mi" > "$RESULTDIR/summary.csv"

for npods in 5 10 20 40; do
  tag="p2_${COLLECTOR}_n${npods}"
  if grep -q "^$tag," "$RESULTDIR/summary.csv" 2>/dev/null; then
    echo "skip $tag (already done)"; continue
  fi
  run_one "$COLLECTOR" "$RMAX" "$npods" "$STEADY" "$tag"
done

# File descriptor release test at 40 containers
echo "=== fd release test ($COLLECTOR) ==="
FDLOG="$RESULTDIR/fd_release_${COLLECTOR}.csv"
echo "ts,fd_pod1,fd_pod2" > "$FDLOG"
echo "steady-state fd counts:"
pods=($(collector_pods))
for i in $(seq 1 4); do
  f1=$(collector_fd_count "${pods[0]}"); f2=$(collector_fd_count "${pods[1]}")
  echo "$(date +%T),$f1,$f2" | tee -a "$FDLOG"
  sleep 15
done
echo "deleting all generator pods..."
oc scale deploy "$LG" -n "$LGNS" --replicas=0
t0=$(date +%s)
for i in $(seq 1 60); do
  f1=$(collector_fd_count "${pods[0]}"); f2=$(collector_fd_count "${pods[1]}")
  echo "$(date +%T),$f1,$f2" | tee -a "$FDLOG"
  # stop when both pods release (fd count back near baseline ~20) or 15 min
  if [[ -n "$f1" && -n "$f2" && "$f1" -lt 30 && "$f2" -lt 30 ]]; then
    echo "fds released after $(( $(date +%s) - t0 ))s"; break
  fi
  sleep 15
done
echo "fd release test complete: $FDLOG"
