#!/usr/bin/env bash
# Release through Git: render the Rollout for <tag>, commit, push, and let
# ArgoCD reconcile it. This is the "real" path; scripts/deploy-version.sh is the
# local shortcut that applies the same render with kubectl.
#
#   ./scripts/bump-and-push.sh v2        # healthy release
#   ./scripts/bump-and-push.sh v3 100    # release that fails 100% of /api/orders
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

VERSION="${1:?usage: bump-and-push.sh <tag> [fail_rate]}"
FAIL_RATE="${2:-0}"
MANIFEST=apps/orders-api/rollout.yaml

tmp=$(mktemp)
python3 scripts/render-version.py "$VERSION" "$VERSION" "$FAIL_RATE" "$MANIFEST" > "$tmp"
mv "$tmp" "$MANIFEST"

if git diff --quiet -- "$MANIFEST"; then
  echo "$MANIFEST already at ${VERSION} (fail_rate=${FAIL_RATE}%), nothing to commit"
else
  git add "$MANIFEST"
  git commit -q -m "release: orders-api ${VERSION} (fail_rate=${FAIL_RATE}%)"
  git push -q
  echo "pushed: ${VERSION} (fail_rate=${FAIL_RATE}%)"
fi

# Ask ArgoCD to look at the repo now instead of waiting for its 3-minute poll.
kubectl annotate application orders-api -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

echo "waiting for ArgoCD to sync..."
for _ in $(seq 1 40); do
  st=$(kubectl get application orders-api -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  rev=$(kubectl get application orders-api -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null | cut -c1-7)
  [ "$rev" = "$(git rev-parse --short HEAD)" ] && { echo "synced to $rev (sync=$st)"; break; }
  sleep 5
done

echo "rollout phase: $(kubectl get rollout orders-api -n orders -o jsonpath='{.status.phase}')"
echo "follow it with: kubectl argo rollouts get rollout orders-api -n orders --watch"
