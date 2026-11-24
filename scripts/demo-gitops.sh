#!/usr/bin/env bash
# Same two scenarios as scripts/demo.sh, but released through Git: every step is
# a commit + push, ArgoCD reconciles, Argo Rollouts runs the canary.
#
#   ./scripts/demo-gitops.sh
#
# Evidence lands in docs/evidence/06..08-*.txt. Requires the ArgoCD Application
# (platform/argocd/application.yaml) and a pushable origin.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

EV=docs/evidence
mkdir -p "$EV"
KRO="kubectl argo rollouts"
NS=orders
APP=orders-api

hr() { printf '\n=== %s ===\n' "$1"; }
phase() { kubectl get rollout orders-api -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }

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
  echo "TIMEOUT phase=${want} (last: ${st:-unknown})" >&2
  return 1
}

app_state() { # sync / revision / health as seen by ArgoCD
  kubectl get application "$APP" -n argocd -o jsonpath='sync={.status.sync.status} revision={.status.sync.revision} health={.status.health.status}{"\n"}'
}

traffic_sample() {
  local i
  for i in $(seq 1 20); do
    curl -s -o /dev/null -D - -H 'Host: orders.local' --max-time 3 \
      "http://127.0.0.1:8080/api/orders" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="x-app-version:" {print $2}'
  done | sort | uniq -c
}

# ArgoCD reports a canary in a pause step as "Suspended", and the old pods keep
# serving for a few seconds after promotion: settle before sampling.
settle() { sleep "${1:-30}"; }

hr "A. release v2 through Git"
./scripts/bump-and-push.sh v2 0
wait_phase Healthy 480 || exit 1
settle 30
{ echo "=== ArgoCD ==="; app_state
  echo "=== Rollout ==="; $KRO get rollout orders-api -n "$NS" | sed -n '1,12p'
  echo "=== trafic (attendu 100% v2) ==="; traffic_sample; } | tee "$EV/06-argocd-sync-v2.txt"

hr "B. release v3 with FAIL_RATE=100 through Git"
./scripts/bump-and-push.sh v3 100
wait_phase Degraded 600
settle 25
{ echo "=== ArgoCD (Degraded attendu : la spec v3 est dans Git, les pods servent v2) ==="
  app_state
  echo "=== Rollout ==="; $KRO get rollout orders-api -n "$NS" | sed -n '1,14p'
  echo "=== message d'abandon ==="; kubectl get rollout orders-api -n "$NS" -o jsonpath='{.status.message}{"\n"}'
  echo "=== trafic (attendu 100% v2) ==="; traffic_sample; } | tee "$EV/07-argocd-auto-rollback.txt"

hr "C. revert the release in Git (rollback, GitOps style)"
./scripts/bump-and-push.sh v2 0
wait_phase Healthy 600
settle 30
{ echo "=== ArgoCD ==="; app_state
  echo "=== Rollout ==="; $KRO get rollout orders-api -n "$NS" | sed -n '1,12p'
  echo "=== trafic (attendu 100% v2) ==="; traffic_sample; } | tee "$EV/08-argocd-reverted.txt"

hr "evidence written to $EV/"
ls -1 "$EV" | tail -4
