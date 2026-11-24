#!/usr/bin/env bash
# Rebuild the whole demo from scratch: Kind cluster, ingress-nginx, Argo Rollouts,
# Prometheus, the three image tags of orders-api, then the application manifests.
#
#   ./scripts/bootstrap.sh
#
# Works with Docker or with rootless Podman acting as `docker` (KIND_EXPERIMENTAL_PROVIDER
# is set automatically in that case). Nothing here needs root.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=${CLUSTER:-orders-demo}
ROLLOUTS_VERSION=${ROLLOUTS_VERSION:-v1.10.2}
INGRESS_VERSION=${INGRESS_VERSION:-controller-v1.15.1}
PROM_CHART_VERSION=${PROM_CHART_VERSION:-30.0.0}
API_DIR=${API_DIR:-../orders-api}

# --- tool detection ----------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 — $2"; exit 1; }; }
need kind "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
need kubectl "https://kubernetes.io/docs/tasks/tools/"
need helm "https://helm.sh/docs/intro/install/"
[[ -x ~/.local/bin/kubectl-argo-rollouts ]] || echo "warning: kubectl-argo-rollouts plugin not found (kubectl argo rollouts will not work)"

if ! command -v docker >/dev/null 2>&1; then
  echo "no docker binary; expecting podman to be aliased or used directly"
fi
if docker --version 2>/dev/null | grep -qi podman; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  BUILD_OPTS="--format docker"   # podman keeps the docker manifest format Kind expects
  echo "using podman as the container runtime"
else
  BUILD_OPTS=""
fi

# --- 1. cluster --------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster $CLUSTER already exists, reusing it"
else
  kind create cluster --config cluster/kind-config.yaml --wait 180s
fi

# --- 2. ingress-nginx --------------------------------------------------------
echo "== ingress-nginx $INGRESS_VERSION =="
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl wait --namespace ingress-nginx --for=condition=Ready \
  pod --selector=app.kubernetes.io/component=controller --timeout=240s
# The pod cgroup in Kind allows ~307 pids; nginx defaults to one worker per CPU
# plus its threads and some workers die with "pthread_create() failed (11)" when
# the node has many cores. Two workers are plenty here and stable.
kubectl patch configmap ingress-nginx-controller -n ingress-nginx --type merge \
  -p '{"data":{"worker-processes":"2"}}'
kubectl rollout restart deploy/ingress-nginx-controller -n ingress-nginx
kubectl rollout status deploy/ingress-nginx-controller -n ingress-nginx --timeout=180s

# --- 3. Argo Rollouts --------------------------------------------------------
echo "== argo-rollouts $ROLLOUTS_VERSION =="
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the rollout/analysisrun CRDs are bigger than the 256KB
# last-applied-configuration annotation limit of client-side apply.
kubectl apply --server-side --force-conflicts -n argo-rollouts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/install.yaml"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argo-rollouts \
  -n argo-rollouts --timeout=240s

# --- 4. Prometheus -----------------------------------------------------------
echo "== prometheus chart $PROM_CHART_VERSION =="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
if helm status prometheus -n monitoring >/dev/null 2>&1; then
  echo "prometheus already installed"
else
  helm install prometheus prometheus-community/prometheus -n monitoring --create-namespace \
    -f platform/prometheus/values.yaml --version "$PROM_CHART_VERSION"
fi
kubectl wait --for=condition=Ready pods --all -n monitoring --timeout=240s

# --- 5. images ---------------------------------------------------------------
echo "== building orders-api images =="
for v in v1 v2 v3; do
  # shellcheck disable=SC2086
  docker build $BUILD_OPTS -q -t "ghcr.io/abi0066/orders-api:${v}" "$API_DIR" >/dev/null
  kind load docker-image "ghcr.io/abi0066/orders-api:${v}" --name "$CLUSTER"
done

# --- 6. application ----------------------------------------------------------
echo "== applying apps/orders-api =="
kubectl apply -k apps/orders-api
kubectl wait --for=condition=Available deployment/loadgen -n orders --timeout=180s
kubectl argo rollouts status orders-api -n orders --timeout 240s || true

echo
echo "Ready. Next:"
echo "  curl -H 'Host: orders.local' http://127.0.0.1:8080/health"
echo "  ./scripts/demo.sh"
