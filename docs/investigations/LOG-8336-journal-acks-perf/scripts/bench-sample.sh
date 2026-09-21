#!/usr/bin/env bash
# Sample source read rate, delivered rate, and buffer growth over time for the target collector pod.
set -euo pipefail
PHASE="${1:-unlabeled}"
SAMPLES="${SAMPLES:-12}"
INTERVAL="${INTERVAL:-20}"
NODE="${TARGET_NODE:-ip-10-0-1-18.ec2.internal}"
SINK="${SINK:-output_lokistack_output_infrastructure}"
SRC='input_journal_only_journal'

TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/instance=collector \
  --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')

q() { curl -s -H "Authorization: Bearer $TOKEN" --data-urlencode "query=$1" \
  "https://$THANOS/api/v1/query" \
  | python3 -c 'import sys,json;r=json.load(sys.stdin).get("data",{}).get("result",[]);print(r[0]["value"][1] if r else "NaN")'; }

echo "================ SAMPLE PHASE: $PHASE  (pod=$POD) ================"
printf '%-9s %-14s %-14s %-14s %-16s\n' "t(s)" "read_ev/s" "delivered/s" "buf_events" "buf_bytes"
t=0
for i in $(seq 1 "$SAMPLES"); do
  READ=$(q "sum(rate(vector_component_sent_events_total{component_id=\"$SRC\",pod=\"$POD\"}[1m]))")
  DEL=$(q "sum(rate(vector_component_sent_events_total{component_id=\"$SINK\",component_kind=\"sink\",pod=\"$POD\"}[1m]))")
  BE=$(q "max(vector_buffer_events{component_id=\"$SINK\",pod=\"$POD\"})")
  BB=$(q "max(vector_buffer_byte_size{component_id=\"$SINK\",pod=\"$POD\"})")
  printf '%-9s %-14.1f %-14.1f %-14.0f %-16.0f\n' "$t" "${READ/NaN/0}" "${DEL/NaN/0}" "${BE/NaN/0}" "${BB/NaN/0}" 2>/dev/null \
    || printf '%-9s %-14s %-14s %-14s %-16s\n' "$t" "$READ" "$DEL" "$BE" "$BB"
  sleep "$INTERVAL"; t=$((t+INTERVAL))
done
