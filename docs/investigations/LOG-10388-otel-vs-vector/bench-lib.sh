#!/bin/bash
# Shared library for the OTEL-vs-Vector benchmark (LOG-10388)
# Requires: oc (kubeconfig set by caller), jq
set -uo pipefail

NS=openshift-logging
LGNS=loadgen
# collector mode: OTEL=0 (vector, default) or OTEL=1 (otel collector).
# otel_init() switches namespace, pod selection and loki label mapping.
OTEL=0
CNS=openshift-logging            # namespace the collector pods run in
CLBL=kubernetes_namespace_name   # loki label produced by the collector
otel_init() {
  OTEL=1
  CNS=openshift-opentelemetry-collector
  CLBL=k8s_namespace_name        # LokiStack OTLP maps only k8s.* resource attrs
}
MULTI=0  # 1 = generator spread across loadgen0-3 (multi-pipeline mode)
LGNS_ALL="loadgen0 loadgen1 loadgen2 loadgen3"
LG=load-client
GATEWAY="https://logging-loki-gateway-http.openshift-logging.svc.cluster.local:8080/api/logs/v1/application/loki/api/v1"
RESULTDIR="${BASH_SOURCE[0]%/*}/results"
mkdir -p "$RESULTDIR"

query_token() {
  oc get secret logcollector-sa-token -n "$NS" -o jsonpath='{.data.token}' | base64 -d
}

# loki_query "query" [timestamp-seconds] -> raw JSON
loki_instant() {
  local q="$1" ts="${2:-}"
  local TOKEN; TOKEN=$(query_token)
  local args=(curl -s -G -k "$GATEWAY/query"
    --data-urlencode "query=$q"
    -H "Authorization: Bearer $TOKEN")
  [[ -n "$ts" ]] && args+=(--data-urlencode "time=$ts")
  oc exec -n "$NS" querycli -- "${args[@]}" 2>/dev/null
}

# delivered per 1m window: sum(count_over_time({ns}[1m])) at time T
loki_rate_1m() {
  local ts="$1"
  loki_instant "sum(count_over_time({$CLBL=~\"loadgen|loadgen0|loadgen1|loadgen2|loadgen3\"}[1m]))" "$ts" \
    | jq -r '.data.result[0].value[1] // 0'
}

# count delivered over [start,end] via count_over_time at end with window
loki_delivered_window() {
  local start="$1" end="$2"
  local win=$((end-start))
  loki_instant "sum(count_over_time({$CLBL=~\"loadgen|loadgen0|loadgen1|loadgen2|loadgen3\"}[${win}s]))" "$end" \
    | jq -r '.data.result[0].value[1] // 0'
}

# collector pod names on worker nodes (all collector pods)
collector_pods() {
  if [[ $OTEL == 1 ]]; then
    oc get pods -n "$CNS" --no-headers 2>/dev/null | awk '$1 ~ /^otel-collector-collector-/ && $3 == "Running" {print $1}'
  else
    oc get pods -n "$NS" -l app.kubernetes.io/component=collector -o name | cut -d/ -f2
  fi
}

# fd count of the vector/otelc process in a collector pod
collector_fd_count() {
  local pod="$1"
  oc exec -n "$CNS" "$pod" -- sh -c 'ls /proc/1/fd 2>/dev/null | wc -l' 2>/dev/null
}

# sample resource usage of all collector pods -> "cpu_millis mem_mib" (max across pods)
collector_usage() {
  local pat='^collector-'; [[ $OTEL == 1 ]] && pat='^otel-collector-collector-'
  oc adm top pod -n "$CNS" --no-headers 2>/dev/null | awk -v p="$pat" '$1 ~ p {gsub("m","",$2); if($2+0>cpu)cpu=$2+0; gsub("Mi","",$3); if($3+0>mem)mem=$3+0} END {printf "%d %d", cpu+0, mem+0}'
}

# in-cluster Prometheus instant query (thanos-querier, admin token) -> raw JSON
prom_instant() {
  local q="$1"
  local token; token=$(oc whoami -t)
  oc exec -n "$NS" querycli -- curl -sk -G "https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query" \
    --data-urlencode "query=$q" -H "Authorization: Bearer $token" 2>/dev/null
}

# total events read by the collector's kubernetes_logs source, summed across
# collector pods (from in-cluster Prometheus; counter-reset safe)
vector_source_events() {
  prom_instant 'sum(vector_component_received_events_total{component_kind="source",component_type="kubernetes_logs"})' \
    | jq -r '.data.result[0].value[1] // 0'
}

# exact total lines generated: sum of the max sequence number embedded in the
# last line of each LIVE load-client pod's node log file (monotonic per pod,
# rotation-safe; verified seq == file line count per pod).
# Two former inflation bugs, both fixed here:
#  1. stale /var/log/pods dirs of deleted pods linger until kubelet GC —
#     filter last-lines by live pod names.
#  2. oc debug silently drops output for some pods; a snapshot that misses a
#     pod makes the NEXT snapshot's delta include that pod's whole cumulative
#     seq. Fix: retry each node until its 'goloader seq' line count equals the
#     number of live pods scheduled on that node (per oc get pods -o wide).
generator_seq_total() {
  local pods
  if [[ $MULTI == 1 ]]; then
    pods=$(for ns in $LGNS_ALL "$LGNS"; do oc get pods -n "$ns" -l app=load-client --no-headers 2>/dev/null | awk '{print $1}'; done)
  else
    pods=$(oc get pods -n "$LGNS" -l app=load-client --no-headers 2>/dev/null | awk '{print $1}')
  fi
  [[ -z "$pods" ]] && { echo 0; return; }
  local pf; pf=$(mktemp); printf '%s\n' "$pods" > "$pf"
  # expected live pods per node
  local wide; wide=$(oc get pods -A -o wide --no-headers 2>/dev/null | awk '$1 ~ /^loadgen/ && /load-client/ {print $8 "|" $2}')
  local best=0 r node
  for r in 1 2; do
    local total=0 n
    for node in $(oc get nodes -o name); do
      local nname=${node#node/}
      local want; want=$(echo "$wide" | grep -F "$nname" | wc -l)
      local try
      for try in 1 2 3 4; do
        n=$(oc debug "$node" -- chroot /host sh -c \
          'for d in /var/log/pods/loadgen*_load-client-*_*/load-client; do [ -f "$d/0.log" ] && tail -1 "$d/0.log"; done; true' 2>&1 \
          | grep 'goloader seq' | grep -F -f "$pf" \
          | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]{10}$/){s=$i; gsub(/^0+/,"",s); sum+=s; c++}} END{printf "%d %d", sum+0, c+0}')
        local got=${n#* }
        [[ "$got" == "$want" ]] && break
        sleep 3
      done
      total=$(( total + ${n% *} ))
    done
    (( total > best )) && best=$total
  done
  rm -f "$pf"
  echo "$best"
}

# events read by the collector source over the last <secs> seconds
# (instant sums at window edges via query_time; avoids increase() extrapolation)
vector_source_increase() {
  local secs="$1" now; now=$(date +%s)
  local t0=$(( now - secs ))
  local a b
  a=$(prom_instant_at 'sum(vector_component_received_events_total{component_kind="source",component_type="kubernetes_logs"})' "$t0" | jq -r '.data.result[0].value[1] // 0')
  b=$(prom_instant_at 'sum(vector_component_received_events_total{component_kind="source",component_type="kubernetes_logs"})' "$now" | jq -r '.data.result[0].value[1] // 0')
  python3 -c "print(max(0, float($b) - float($a)))"
}

# in-cluster Prometheus instant query at a specific eval time
prom_instant_at() {
  local q="$1" ts="$2"
  local token; token=$(oc whoami -t)
  oc exec -n "$NS" querycli -- curl -sk -G "https://thanos-querier.openshift-monitoring.svc:9091/api/v1/query" \
    --data-urlencode "query=$q" --data-urlencode "time=$ts" -H "Authorization: Bearer $token" 2>/dev/null
}

# validate generator actual output rate: count lines emitted in a 30s window
generator_actual_rate() {
  local sns="$LGNS"; [[ $MULTI == 1 ]] && sns=loadgen0
  local pod; pod=$(oc get pods -n "$sns" -l app=load-client -o name | head -1 | cut -d/ -f2)
  local a b
  a=$(oc logs -n "$LGNS" "$pod" --since=40s 2>/dev/null | wc -l)
  sleep 30
  b=$(oc logs -n "$LGNS" "$pod" --since=30s 2>/dev/null | wc -l)
  echo $(( b ))  # lines in last 30s
}

set_generator() {
  local replicas="$1" rate="$2"
  if [[ $MULTI == 1 ]]; then
    local ns
    for ns in $LGNS_ALL; do
      oc patch deploy "$LG" -n "$ns" --type strategic -p \
        "{\"spec\":{\"replicas\":$replicas,\"template\":{\"spec\":{\"containers\":[{\"name\":\"load-client\",\"args\":[\"--synthetic-payload-size=512\",\"--log-format=default\",\"--logs-per-second=$rate\"]}]}}}}"
      oc rollout status deploy/"$LG" -n "$ns" --timeout=180s >/dev/null
    done
  else
    oc patch deploy "$LG" -n "$LGNS" --type strategic -p \
      "{\"spec\":{\"replicas\":$replicas,\"template\":{\"spec\":{\"containers\":[{\"name\":\"load-client\",\"args\":[\"--synthetic-payload-size=512\",\"--log-format=default\",\"--logs-per-second=$rate\"]}]}}}}"
  fi
}

# OTEL: total log records accepted by the file_log receiver, summed across
# collector pods (self-metrics at http://<pod-ip>:8888/metrics)
otel_receiver_total() {
  local total=0 p ip n
  for p in $(collector_pods); do
    ip=$(oc get pod -n "$CNS" "$p" -o jsonpath='{.status.podIP}' 2>/dev/null)
    [[ -z "$ip" ]] && continue
    # counter renders in scientific notation above 1e6 ("2.27e+06") —
    # normalize to int or downstream $(( )) arithmetic aborts the script
    n=$(oc exec -n "$NS" querycli -- curl -s "http://$ip:8888/metrics" 2>/dev/null \
      | awk '/^otelcol_receiver_accepted_log_records\{/{print $2}' | head -1)
    total=$(python3 -c "print(int($total + ${n:-0}))")
  done
  echo "$total"
}

# source read-rate events total, mode-aware (vector: prometheus counter; otel: self-metrics)
source_events_total() {
  if [[ $OTEL == 1 ]]; then otel_receiver_total; else vector_source_events; fi
}

# wait until the system is quiesced: generator off, ingester WAL drained,
# and the collector has read its on-disk backlog (source rate ~ 0). Max ~20 min.
drain_gate() {
  echo "[$(date +%T)] drain gate: waiting for quiescence"
  if [[ $MULTI == 1 ]]; then
    local ns
    for ns in $LGNS_ALL; do oc scale deploy "$LG" -n "$ns" --replicas=0 >/dev/null 2>&1; done
  else
    oc scale deploy "$LG" -n "$LGNS" --replicas=0 >/dev/null
  fi
  local deadline=$(( $(date +%s) + 1200 ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local wal_ok=0 src_ok=0
    local wal; wal=$(oc exec -n "$NS" logging-loki-ingester-0 -- du -sm /tmp/wal 2>/dev/null | awk '{print $1}')
    [[ -n "$wal" && "$wal" -lt 2000 ]] && wal_ok=1
    local a b; a=$(source_events_total); sleep 30; b=$(source_events_total)
    local rate; rate=$(python3 -c "print(int((${b:-0} - ${a:-0}) / 30))")
    [[ ${rate:-999} -lt 200 ]] && src_ok=1
    echo "[$(date +%T)] drain: wal=${wal}Mi collector_reads=${rate}/s wal_ok=$wal_ok src_ok=$src_ok"
    [[ $wal_ok == 1 && $src_ok == 1 ]] && { echo "[$(date +%T)] drained"; return 0; }
  done
  echo "[$(date +%T)] drain gate timed out; continuing anyway" >&2
}

# run_one <collector-label> <total-rate> <n-pods> <steady-seconds> <tag>
# Assumes generator already running at desired rate; performs warmup + sampling.
run_one() {
  local label="$1" rate="$2" npods="$3" steady="$4" tag="$5"
  drain_gate
  local perpod
  if [[ $MULTI == 1 ]]; then
    # 4 namespaces, one per pipeline; split the total rate across them
    local ns_pods=$(( (rate / 4 + 4999) / 5000 )); [[ $ns_pods -lt 1 ]] && ns_pods=1
    perpod=$(( rate / 4 / ns_pods ))
    npods=$(( ns_pods * 4 ))
    set_generator "$ns_pods" "$perpod"
  else
    perpod=$(( rate / npods ))
    set_generator "$npods" "$perpod"
    oc rollout status deploy/"$LG" -n "$LGNS" --timeout=180s >/dev/null
  fi
  echo "[$(date +%T)] tag=$tag rate=$rate npods=$npods perpod=$perpod: rolling out"
  sleep 30  # let new pods start producing before measuring

  # validate actual generator rate (per pod); lines counted over a 30s window
  local actual; actual=$(generator_actual_rate)
  local measured=$(( actual / 30 ))
  echo "[$(date +%T)] generator log-rate sample: $measured/s per pod (target $perpod; undercounts at high rates due to rotation)"

  # warm-up 3 min
  echo "[$(date +%T)] warm-up 180s"
  sleep 180

  local samples="$RESULTDIR/${tag}_samples.csv"
  echo "ts,delivered_1m,cpu_milli,mem_mib,fd_bktjh,fd_mv7sh" > "$samples"

  echo "[$(date +%T)] steady state ${steady}s"
  local t_start=$(date +%s)
  local seq_start; seq_start=$(generator_seq_total)
  local t_end=$(( t_start + steady ))
  local delivered_total=0
  while [[ $(date +%s) -lt $t_end ]]; do
    local now=$(date +%s)
    local d=""
    if (( now % 60 < 15 )); then
      d=$(loki_rate_1m "$now" 2>/dev/null)
      [[ -z "$d" || "$d" == "null" ]] && d=0
    fi
    local usage; usage=$(collector_usage)
    local fd1=$(collector_fd_count "$(collector_pods | head -1)")
    local fd2=$(collector_fd_count "$(collector_pods | tail -1)")
    echo "$(date +%T),$d,${usage% *},${usage#* },$fd1,$fd2" >> "$samples"
    sleep 15
  done

  # delivered total over steady window: one exact count query
  delivered_total=$(loki_delivered_window "$t_start" "$t_end")
  [[ -z "$delivered_total" || "$delivered_total" == "null" ]] && delivered_total=0
  # emitted = NOMINAL: goloader paces writes to exactly --logs-per-second
  # (verified per-pod: seq delta == file line count == target rate). The raw
  # seq delta over this window is unreliable because each generator_seq_total
  # snapshot takes 60-90s (oc debug per node), so the end value is captured
  # well after t_end — the seq "window" is wider than the delivered window.
  # seq delta is kept as a cross-check diagnostic only.
  local seq_end; seq_end=$(generator_seq_total)
  emitted=$(( npods * perpod * steady ))
  local seq_delta=$(( seq_end - seq_start ))
  echo "[$(date +%T)] emitted cross-check: nominal=$emitted seq_delta=$seq_delta ($(python3 -c "print(f'{abs($seq_delta-$emitted)/$emitted*100:.1f}%') if $emitted>0 else print('n/a')") off)"
  # persist window for post-drain delivered re-query (late Loki arrivals)
  echo "$t_start $t_end" > "$RESULTDIR/${tag}_window.txt"
  if [[ $OTEL == 0 ]]; then
    echo "[$(date +%T)] vector source reads in window: $(vector_source_increase "$steady" | python3 -c "import sys; print(round(float(sys.stdin.read() or 0)))")"
  else
    echo "[$(date +%T)] otel receiver records in window: $(otel_receiver_total)"
  fi
  local cpu_med cpu_max mem_med mem_max
  cpu_med=$(tail -n +2 "$samples" | awk -F, '{print $3}' | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]}')
  cpu_max=$(tail -n +2 "$samples" | awk -F, '{if($3>m)m=$3} END{printf "%d", m+0}')
  mem_med=$(tail -n +2 "$samples" | awk -F, '{print $4}' | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]}')
  mem_max=$(tail -n +2 "$samples" | awk -F, '{if($4>m)m=$4} END{printf "%d", m+0}')

  local loss_pct
  loss_pct=$(python3 -c "e=$emitted; d=$delivered_total; print(f'{(e-d)/e*100:.2f}' if e>0 else '0')")
  echo "$tag,$label,$rate,$npods,$steady,$emitted,$delivered_total,$loss_pct,$cpu_med,$cpu_max,$mem_med,$mem_max" \
    >> "$RESULTDIR/summary.csv"
  echo "[$(date +%T)] tag=$tag DONE: emitted=$emitted delivered=$delivered_total loss=${loss_pct}% cpu_med=${cpu_med}m cpu_max=${cpu_max}m mem_med=${mem_med}Mi mem_max=${mem_max}Mi"
}
