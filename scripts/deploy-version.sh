#!/usr/bin/env bash
# Deploy a given release of orders-api into the demo cluster.
#
#   ./scripts/deploy-version.sh v2            # healthy release
#   ./scripts/deploy-version.sh v3 100        # release that fails 100% of /api/orders
#   ./scripts/deploy-version.sh v3 40         # partial degradation
#
# It renders the committed Rollout with the new tag/env and applies it, exactly
# as ArgoCD would after a Git commit -- see README "Once ArgoCD is wired in".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: deploy-version.sh <tag> [fail_rate]}"
FAIL_RATE="${2:-0}"

python3 scripts/render-version.py "$VERSION" "$VERSION" "$FAIL_RATE" \
  | kubectl apply -f - >/dev/null

echo "applied ${VERSION} (fail_rate=${FAIL_RATE}%)"
