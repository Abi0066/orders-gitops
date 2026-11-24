# orders-gitops — progressive delivery with Argo Rollouts on Kind

GitOps-style manifests for a small Node.js **Orders API**, running on a local **Kind**
cluster with **Argo Rollouts** (canary), **ingress-nginx** (real traffic weights) and
**Prometheus** (metric analysis).

The point of the project is not the CRUD API — it is the delivery pipeline, and
specifically this: **a broken release gets rolled back automatically because a
Prometheus query said so, and a healthy one gets promoted because the same query
said so.** Both runs are captured in [`docs/evidence/`](docs/evidence/).

```
$ ./scripts/demo.sh
A. v2 healthy  ->  weight 20% -> 50% -> 100%   AnalysisRun: Successful
B. v3 failing  ->  success-rate = 0            AnalysisRun: Failed -> RolloutAborted
                   traffic stays on v2
```

---

## 1. What it demonstrates

| Capability | How |
|---|---|
| Canary with real traffic weights (not just pod ratios) | ingress-nginx annotations driven by `trafficRouting.nginx` |
| Metric-based promotion **and** rollback | `AnalysisTemplate` querying Prometheus, `successCondition: result[0] >= 0.95` |
| Measurement scoped to the canary only | PromQL filtered on `rollouts_pod_template_hash` |
| Deterministic failure injection | `FAIL_RATE` env var on the same image (0–100 %) |
| Hardened pods | non-root, read-only root filesystem, all capabilities dropped |
| Reproducible from zero | `scripts/bootstrap.sh` (no root, works with rootless Podman) |

## 2. Architecture

```mermaid
flowchart LR
  LG[loadgen<br/>~10 req/s] --> ING[ingress-nginx<br/>orders.local:8080]
  ING -->|80% / 50% / 0%| SVC_S[Service<br/>orders-api-stable]
  ING -->|20% / 50% / 100%| SVC_C[Service<br/>orders-api-canary]
  SVC_S --> P1[orders-api pods<br/>rollouts-pod-template-hash=old]
  SVC_C --> P2[orders-api pods<br/>rollouts-pod-template-hash=new]
  PROM[(Prometheus)] -->|scrape /metrics| P1 & P2
  AR[Argo Rollouts controller] -->|creates / weights| ING
  AR -->|AnalysisRun| PROM
  AR -->|promote / abort| P1 & P2
```

The two `ClusterIP` services both select `app=orders-api`. Argo Rollouts **rewrites
their selectors** to add the pod-template hash — that is the only thing that makes
"stable" and "canary" target different pods. Never hardcode that label by hand.

## 3. Prerequisites

Verified on Fedora 44 with **Podman 6.2 in rootless mode** (no Docker daemon, no root),
6 CPUs, 30 GB RAM.

| Tool | Version used | Notes |
|---|---|---|
| kind | 0.33.0 | `KIND_EXPERIMENTAL_PROVIDER=podman` with rootless Podman |
| kubectl | 1.37.1 | |
| helm | 3.19.2 | only for the Prometheus chart |
| node / npm | 22 (in the image) | local tests run with any Node ≥ 20 |
| kubectl-argo-rollouts | v1.10.2 | `~/.local/bin` is enough, no sudo |

In-cluster versions are pinned in `scripts/bootstrap.sh`:
Kubernetes `v1.37.0` (Kind node image), ingress-nginx `controller-v1.15.1`,
argo-rollouts `v1.10.2`, prometheus-community/prometheus chart `30.0.0`.

## 4. Quick start

```bash
git clone <this repo> && cd orders-gitops
git clone <orders-api repo> ../orders-api      # sibling directory

./scripts/bootstrap.sh   # cluster + ingress + rollouts + prometheus + images + app
./scripts/demo.sh        # the two release scenarios, writes docs/evidence/
```

Check the app from the host — the ingress is published on **8080** (privileged
port 80 is not bindable in rootless Podman):

```bash
curl -H 'Host: orders.local' http://127.0.0.1:8080/health
# {"status":"ok","version":"v1","env":"demo","fail_mode":false,"fail_rate":0}

curl -s -H 'Host: orders.local' http://127.0.0.1:8080/api/orders | jq -r .version
```

Watch the rollout:

```bash
kubectl argo rollouts get rollout orders-api -n orders --watch
```

Release a version by hand (this is what a Git commit + ArgoCD sync would do):

```bash
./scripts/deploy-version.sh v2        # healthy
./scripts/deploy-version.sh v3 100    # 100% of /api/orders returns 500
```

## 5. The four traps this project actually solves

These are the reason the repo exists: the naive version of the pipeline either
**never rolls back** or **rolls back the healthy release**. Each one is a line or
two of YAML, and each one is invisible until you run the demo.

### 5.1 Probes and scrapes dilute the success rate

`/ready` (every 3 s), `/live` (every 10 s) and `/metrics` (every 15 s) all return
200 and easily outnumber real traffic on a quiet demo. Aggregate them and a canary
that fails **every** `/api/orders` request still shows ~99 % success.

→ the query only counts `route="/api/orders"`. The app labels the *matched route
pattern*, not the raw path, so label cardinality stays bounded.

### 5.2 Aggregating stable + canary hides the canary

At weight 20 %, a canary failing 100 % of its requests gives a blended success rate
of 80 % — under many thresholds that still "passes" late in a rollout, and the
number tells you nothing about the new version.

→ `args.canary-hash` with `valueFrom.podTemplateHashValue: Latest`, injected into
the query:

```yaml
query: |
  sum(rate(http_requests_total{route="/api/orders", status=~"2..",
       rollouts_pod_template_hash="{{args.canary-hash}}"}[2m])) ...
```

This works because the Prometheus chart's `kubernetes-pods` job labelmaps pod
labels, so `rollouts-pod-template-hash` becomes the metric label
`rollouts_pod_template_hash`.

### 5.3 A cold start reads as a broken release — and where the fallback goes matters

A pod created 40 s ago has fewer than two samples, so `rate()` returns an empty
vector. Argo Rollouts counts that as a **metric error**, and a run of errors aborts
the rollout. Two fixes, in this order:

1. `initialDelay: 45s` + `consecutiveErrorLimit: 8` so a cold start is tolerated;
2. an explicit fallback — but **the placement is the trap**:

```promql
# WRONG: when every request is a 500 there is no 2xx series at all,
# the whole ratio is empty, and the fallback reports 1.0 -- a broken canary looks perfect.
<ratio> or on() vector(1)

# RIGHT: the numerator degrades to 0 *before* the division;
# only a completely empty result (nothing scraped yet) falls back to 1.
(
  (sum(rate(...{status=~"2.."}[2m])) or on() vector(0))
  /
  clamp_min(sum(rate(...[2m])), 0.001)
)
or on() vector(1)
```

A second metric, `canary-request-volume`, makes "the canary receives no traffic at
all" fail loudly instead of passing for a good result.

### 5.4 PromQL operator precedence

`a or vector(0) / b or vector(1)` is **not** `(a or 0) / (b or 1)`. `or` has the
lowest precedence in PromQL, so it parses as `a or (vector(0)/b) or vector(1)`, and
`result[0]` ends up being an absolute request rate compared against `0.95`. Always
parenthesise; `promtool query instant` or the Prometheus UI is the sanity check.

### 5.5 Kind / rootless-Podman specifics that cost time

- **ingress-nginx workers die** with `pthread_create() failed (11)`: the pods
  cgroup allows ~307 pids and nginx starts one worker per CPU. Fixed by
  `worker-processes: "2"` in the controller ConfigMap (see `bootstrap.sh`).
- **Port 80 is not bindable** on the host in rootless mode → Kind maps
  host `8080`/`8443` to the node's `80`/`443`, and every curl needs
  `-H 'Host: orders.local'`.
- **`kubectl apply` fails on the Rollouts CRDs** ("metadata.annotations: Too long")
  → `kubectl apply --server-side`.
- **Image names need a registry prefix.** `kind load docker-image orders-api:v1`
  lands in containerd as `localhost/orders-api:v1`, which a pod asking for
  `orders-api:v1` will not resolve (it looks for `docker.io/library/...`). Building
  and loading `ghcr.io/abi0066/orders-api:v1` fixes it — and it is the reference the
  project will use once images are pushed to GHCR.
- `imagePullPolicy: IfNotPresent` is mandatory, otherwise Kind tries Docker Hub.

## 6. How the analysis is wired

`apps/orders-api/rollout.yaml` (excerpt):

```yaml
strategy:
  canary:
    stableService: orders-api-stable
    canaryService: orders-api-canary
    trafficRouting:
      nginx:
        stableIngress: orders-api     # Rollouts derives the -canary ingress from it
    steps:
      - setWeight: 20
      - pause: { duration: 90s }
      - setWeight: 50
      - pause: { duration: 90s }
      - setWeight: 100
    analysis:
      templates: [{ templateName: success-rate }]
      startingStep: 1                  # 0-based: start analysing at the 20% step
      args:
        - name: canary-hash
          valueFrom: { podTemplateHashValue: Latest }
```

Debugging commands that were actually useful:

```bash
kubectl argo rollouts get rollout orders-api -n orders
kubectl get analysisrun -n orders -o json | jq '.items[-1].status.metricResults'
kubectl get ingress -n orders -o json | jq '.items[] | {name:.metadata.name, w:.metadata.annotations}'
./scripts/check-analysis-promql.sh <canary-hash>   # runs the query against Prometheus
```

## 7. Repository layout

```
cluster/kind-config.yaml          Kind cluster (ports 8080/8443, ingress-ready label)
platform/prometheus/values.yaml   chart values: no alertmanager/node-exporter/kube-state-metrics
apps/orders-api/                  namespace, services, ingress, Rollout, AnalysisTemplate, loadgen
scripts/bootstrap.sh              cluster + platform + images + app, from zero
scripts/demo.sh                   scenario A (promote) and B (automatic rollback)
scripts/deploy-version.sh         render the Rollout for v1/v2/v3 (+ FAIL_RATE)
scripts/render-version.py         deterministic manifest rendering (no sed on YAML)
scripts/check-analysis-promql.sh  sanity-check the analysis query against Prometheus
docs/evidence/                    captured output of the two scenarios
```

## 8. Deliberate simplifications

- **The image is identical for v1, v2 and v3.** The release is defined by the tag
  and by `APP_VERSION`/`FAIL_RATE`, so a failure can be reproduced without patching
  code. `FAIL_RATE` accepts any value 0–100, which also allows "the canary degrades
  40 % of its traffic" scenarios that are more realistic than a total outage.
- **Prometheus is the chart, not the operator.** No `ServiceMonitor`, no
  kube-prometheus-stack: the annotation-based pod discovery of the plain chart is
  enough and keeps the cluster small (~1 GB RAM saved).
- **No ingress TLS**, no persistence, single-node cluster: this is a demo rig.

## 9. Not done yet (next increments)

- **ArgoCD is not wired in.** Today the manifests are applied with
  `kubectl apply -k apps/orders-api`; the pipeline behaviour is identical, but the
  sync is manual. The plan is an `Application` pointing at this repo's
  `apps/orders-api` path, with `syncPolicy.automated` and **no** `selfHeal` (so an
  out-of-band `deploy-version.sh` is visible as `OutOfSync` instead of being
  silently reverted while demonstrating).
- **CI**: `orders-api` has a test + build + Trivy workflow, but nothing pushes to
  GHCR or bumps the tag in this repo yet — do not read the pipeline as a complete
  CI/CD loop.
- Progressive delivery of a *database-backed* service (migrations, backwards
  compatibility) is out of scope here.

## 10. Cleanup

```bash
kind delete cluster --name orders-demo
```

Everything else (images, helm repo) lives in the Podman store and `~/.cache`.
