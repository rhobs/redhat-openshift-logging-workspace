#!/bin/bash
# Single Vector 20000/s run with the node-labels-suppressed CLO build
# (bench patch: kubernetes_logs node_annotation_fields.node_labels = "").
# Compares against p1_vector_20000 (same rate, labels attached).
set -uo pipefail
cd "$(dirname "$0")"
source ./bench-lib.sh

TAG=p1_vector-nolabels_20000
[[ -f "$RESULTDIR/summary.csv" ]] || echo "tag,collector,rate,n_pods,steady_s,emitted,delivered,loss_pct,cpu_med_m,cpumax_m,mem_med_mi,mem_max_mi" > "$RESULTDIR/summary.csv"
if grep -q "^$TAG," "$RESULTDIR/summary.csv"; then echo "skip $TAG (already done)"; exit 0; fi

run_one vector-nolabels 20000 4 600 "$TAG"

# finalize: drain then re-query the window (late arrivals / index lag)
drain_gate
read -r ws we < "$RESULTDIR/${TAG}_window.txt"
d=$(loki_delivered_window "$ws" "$we")
[[ -z "$d" || "$d" == "null" || "$d" == "0" ]] && { echo "re-query empty; keeping run value"; exit 0; }
e=$(awk -F, -v t="$TAG" '$1==t{print $6}' "$RESULTDIR/summary.csv")
loss=$(python3 -c "print(f'{($e-$d)/$e*100:.2f}')")
awk -F, -v t="$TAG" -v d="$d" -v l="$loss" 'BEGIN{OFS=","} $1==t{$7=d; $8=l} {print}' "$RESULTDIR/summary.csv" > "$RESULTDIR/summary.csv.tmp" && mv "$RESULTDIR/summary.csv.tmp" "$RESULTDIR/summary.csv"
echo "finalized $TAG: delivered=$d loss=$loss%"
