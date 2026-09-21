#!/usr/bin/env bash
# Measure Vector throughput/latency for the collector pod on the target node.
set -euo pipefail
PHASE="${1:-unlabeled}"
NODE="${TARGET_NODE:-ip-10-0-1-18.ec2.internal}"
WIN="${WIN:-3m}"
SINK='output_lokistack_output_infrastructure'
SRC='input_journal_only_journal'

TOKEN=$(oc whoami -t)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
POD=$(oc get pods -n openshift-logging -l app.kubernetes.io/instance=collector \
  --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')

q() { # returns single scalar value or NaN
  curl -s -H "Authorization: Bearer $TOKEN" --data-urlencode "query=$1" \
    "https://$THANOS/api/v1/query" \
  | python3 -c 'import sys,json
d=json.load(sys.stdin);r=d.get("data",{}).get("result",[])
print(r[0]["value"][1] if r else "NaN")'
}

echo "================ PHASE: $PHASE  (pod=$POD, node=$NODE, win=$WIN) ================"
printf '%-38s %s\n' "collector pod" "$POD"
printf '%-38s %s\n' "journal read rate (ev/s)" \
  "$(q "sum(rate(vector_component_sent_events_total{component_id=\"$SRC\",pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "sink delivered throughput (ev/s)" \
  "$(q "sum(rate(vector_component_sent_events_total{component_id=\"$SINK\",component_kind=\"sink\",pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "sink received rate (ev/s)" \
  "$(q "sum(rate(vector_component_received_events_total{component_id=\"$SINK\",component_kind=\"sink\",pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "buffer events (current)" \
  "$(q "max(vector_buffer_events{component_id=\"$SINK\",pod=\"$POD\"})")"
printf '%-38s %s\n' "buffer byte size (current)" \
  "$(q "max(vector_buffer_byte_size{component_id=\"$SINK\",pod=\"$POD\"})")"
printf '%-38s %s\n' "avg loki request RTT (s)" \
  "$(q "sum(rate(vector_adaptive_concurrency_observed_rtt_sum{pod=\"$POD\"}[$WIN]))/sum(rate(vector_adaptive_concurrency_observed_rtt_count{pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "avg in-flight requests" \
  "$(q "sum(rate(vector_adaptive_concurrency_in_flight_sum{pod=\"$POD\"}[$WIN]))/sum(rate(vector_adaptive_concurrency_in_flight_count{pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "avg buffer send duration (s)" \
  "$(q "sum(rate(vector_buffer_send_duration_seconds_sum{component_id=\"$SINK\",pod=\"$POD\"}[$WIN]))/sum(rate(vector_buffer_send_duration_seconds_count{component_id=\"$SINK\",pod=\"$POD\"}[$WIN]))")"
printf '%-38s %s\n' "sink component p50 latency (s)" \
  "$(q "histogram_quantile(0.5, sum(rate(vector_component_latency_seconds_bucket{component_id=\"$SINK\",pod=\"$POD\"}[$WIN])) by (le))")"
printf '%-38s %s\n' "sink component p95 latency (s)" \
  "$(q "histogram_quantile(0.95, sum(rate(vector_component_latency_seconds_bucket{component_id=\"$SINK\",pod=\"$POD\"}[$WIN])) by (le))")"
printf '%-38s %s\n' "collector CPU (cores)" \
  "$(q "sum(rate(container_cpu_usage_seconds_total{namespace=\"openshift-logging\",pod=\"$POD\",container=\"collector\"}[$WIN]))")"
printf '%-38s %s\n' "collector mem working set (bytes)" \
  "$(q "sum(container_memory_working_set_bytes{namespace=\"openshift-logging\",pod=\"$POD\",container=\"collector\"})")"
echo
