#!/usr/bin/env bash
# End-to-end demo, from a clean baseline to a captured automatic rollback.
#
#   ./scripts/demo.sh
#
# Scenario A: v2 is healthy  -> canary goes 20% -> 50% -> 100%, AnalysisRun Successful
# Scenario B: v3 fails 100%  -> success-rate drops to 0, AnalysisRun Failed,
#                               Rollouts aborts the release and v2 keeps serving
#
# Everything it prints is also written to docs/evidence/, which is what the
# README links to.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

EV=docs/evidence
mkdir -p "$EV"
KRO="kubectl argo rollouts"
NS=orders

hr() { printf '\n=== %s ===\n' "$1"; }

# `kubectl argo rollouts get` has no -o json, so read the phase from the CR.
phase() { kubectl get rollout orders-api -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }

latest_analysisrun() {
  kubectl get analysisrun -n "$NS" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1
}

wait_phase() { # wait_phase <Phase> <seconds>
  local want="$1"
  local secs="${2:-300}"
  local deadline=$((SECONDS + secs))
  local st=""
  while [ $SECONDS -lt $deadline ]; do
    st=$(phase)
    [ "$st" = "$want" ] && return 0
    sleep 5
  done
  echo "TIMEOUT waiting for phase=${want} (last phase: ${st:-unknown})" >&2
  return 1
}

traffic_sample() { # 20 requests through the ingress, count X-App-Version
  local i
  for i in $(seq 1 20); do
    curl -s -o /dev/null -D - -H 'Host: orders.local' --max-time 3 \
      "http://127.0.0.1:8080/api/orders" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="x-app-version:" {print $2}'
  done | sort | uniq -c
}

capture_analysisrun() { # capture_analysisrun <file> -- the run of the last revision
  local ar
  ar=$(latest_analysisrun)
  [ -z "$ar" ] && return 0
  kubectl get "$ar" -n "$NS" -o yaml > "$1"
}

hr "0. baseline: v1 healthy"
./scripts/deploy-version.sh v1 0
wait_phase Healthy 360 || exit 1
$KRO get rollout orders-api -n "$NS" | tee "$EV/01-baseline-v1.txt"

hr "A. releasing v2 (healthy)"
./scripts/deploy-version.sh v2 0
sleep 30
$KRO get rollout orders-api -n "$NS" | tee "$EV/02-canary-v2-20pct.txt"
if wait_phase Healthy 420; then
  { $KRO get rollout orders-api -n "$NS"
    echo "--- trafic réellement servi (attendu : 100% v2) ---"
    traffic_sample; } | tee "$EV/03-canary-v2-promoted.txt"
  capture_analysisrun "$EV/03-analysisrun-v2-successful.yaml"
else
  echo "ERROR: v2 was not promoted" >&2
  exit 1
fi

hr "B. releasing v3 with FAIL_RATE=100 (broken)"
./scripts/deploy-version.sh v3 100
sleep 30
$KRO get rollout orders-api -n "$NS" | tee "$EV/04-canary-v3-20pct.txt"
if wait_phase Degraded 480; then
  echo "rollout aborted by the metric analysis, as expected"
else
  echo "ERROR: the rollout was not aborted" >&2
fi
# Let nginx reload its upstream weights and the canary pods terminate, otherwise
# the traffic sample still catches the last seconds of the 20% canary.
sleep 25
{ $KRO get rollout orders-api -n "$NS"
  echo "--- message d'abandon ---"
  kubectl get rollout orders-api -n "$NS" -o jsonpath='{.status.message}{"\n"}'
  echo "--- trafic réellement servi après rollback (attendu : 100% v2) ---"
  traffic_sample; } | tee "$EV/05-auto-rollback.txt"
capture_analysisrun "$EV/05-analysisrun-v3-failed.yaml"

hr "evidence written to $EV/"
ls -1 "$EV"
