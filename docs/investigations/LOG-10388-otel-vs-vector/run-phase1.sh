#!/bin/bash
# Phase 1 — Find the ceiling (single container), Vector first (LOG-10388)
# Ladder of rates; 10-min steady state per spec; stop when loss >1% or CPU/mem at limits.
set -uo pipefail
cd "$(dirname "$0")"
source ./bench-lib.sh

COLLECTOR=vector
RATES=(2500 5000 10000 20000 40000)
STEADY=600
LOSS_THRESHOLD=1.0
CPU_LIMIT_M=6000
MEM_LIMIT_MI=2048

[[ -f "$RESULTDIR/summary.csv" ]] || echo "tag,collector,rate,n_pods,steady_s,emitted,delivered,loss_pct,cpu_med_m,cpumax_m,mem_med_mi,mem_max_mi" > "$RESULTDIR/summary.csv"

for rate in "${RATES[@]}"; do
  tag="p1_${COLLECTOR}_${rate}"
  # skip if already done (resumable)
  if grep -q "^$tag," "$RESULTDIR/summary.csv" 2>/dev/null; then
    echo "skip $tag (already done)"; continue
  fi
  # single load-client pod tops out ~6666/s; spread across pods at <=5000/s each
  npods=$(( (rate + 4999) / 5000 ))
  [[ $npods -lt 1 ]] && npods=1
  run_one "$COLLECTOR" "$rate" "$npods" "$STEADY" "$tag"
  row=$(grep "^$tag," "$RESULTDIR/summary.csv")
  loss=$(echo "$row" | cut -d, -f8); cpumax=$(echo "$row" | cut -d, -f10); memmax=$(echo "$row" | cut -d, -f12)
  echo "check saturation: loss=$loss cpu_max=$cpumax mem_max=$memmax"
  if (( $(echo "$loss > $LOSS_THRESHOLD" | bc -l) )); then
    echo "SATURATED: loss ${loss}% > ${LOSS_THRESHOLD}%"; break
  fi
  if (( cpumax >= CPU_LIMIT_M )); then
    echo "SATURATED: cpu ${cpumax}m at limit ${CPU_LIMIT_M}m"; break
  fi
  if (( memmax >= MEM_LIMIT_MI )); then
    echo "SATURATED: mem ${memmax}Mi at limit ${MEM_LIMIT_MI}Mi"; break
  fi
done

# finalize: let the system drain, then re-query each window's delivered count
# (Loki may deliver entries after t_end; the window query at t_end misses them)
echo "final drain before delivered re-query"
drain_gate
for w in "$RESULTDIR"/p1_*_window.txt; do
  [[ -f "$w" ]] || continue
  tag=$(basename "$w" _window.txt)
  read -r ws we < "$w"
  d=$(loki_delivered_window "$ws" "$we")
  # guard: a 0/empty re-query means Loki can no longer see the window (aged out
  # or from a previous cluster) — keep the existing value instead of clobbering
  [[ -z "$d" || "$d" == "null" || "$d" == "0" ]] && continue
  e=$(awk -F, -v t="$tag" '$1==t{print $6}' "$RESULTDIR/summary.csv")
  [[ -z "$e" || "$e" -le 0 ]] && continue
  loss=$(python3 -c "print(f'{($e-$d)/$e*100:.2f}')")
  sed -i -E "s|^$tag,(.*)|$tag,\1|" "$RESULTDIR/summary.csv"  # no-op guard
  awk -F, -v t="$tag" -v d="$d" -v l="$loss" 'BEGIN{OFS=","} $1==t{$7=d; $8=l} {print}' "$RESULTDIR/summary.csv" > "$RESULTDIR/summary.csv.tmp" && mv "$RESULTDIR/summary.csv.tmp" "$RESULTDIR/summary.csv"
  echo "finalized $tag: delivered=$d loss=$loss%"
done
echo "Phase 1 ladder complete. See $RESULTDIR/summary.csv"
