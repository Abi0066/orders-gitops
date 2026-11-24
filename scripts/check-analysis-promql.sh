#!/usr/bin/env bash
# Sanity-check the AnalysisTemplate PromQL against the live Prometheus.
set -u
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 >/tmp/pf-prom.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 40); do curl -sf http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && break; sleep 0.25; done

HASH="${1:?usage: $0 <canary-hash>}"
q() {
  local label="$1" query="$2"
  printf '%-28s ' "$label"
  curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$query" \
    | jq -r 'if (.data.result | length) == 0 then "VIDE (=> erreur de métrique)" else .data.result[0].value[1] end'
}

BASE='namespace="orders",route="/api/orders",rollouts_pod_template_hash="'"$HASH"'"'
q "2xx réels" "(sum(rate(http_requests_total{$BASE,status=~\"2..\"}[2m])) or on() vector(0)) / clamp_min(sum(rate(http_requests_total{$BASE}[2m])), 0.001) or on() vector(1)"
q "simulation 5xx (ne doit=0)" "(sum(rate(http_requests_total{$BASE,status=~\"5..\"}[2m])) or on() vector(0)) / clamp_min(sum(rate(http_requests_total{$BASE}[2m])), 0.001) or on() vector(1)"
q "volume" "sum(rate(http_requests_total{$BASE}[2m]))"
