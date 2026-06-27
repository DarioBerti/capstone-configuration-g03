# EuroTransit — local cluster & platform bootstrap runbook.
# Run `just` (no args) to list all recipes.
# Requires: docker, kind, kubectl, helm, just.

# kind cluster name + kubeconfig context (match bootstrap/kind-config.yaml)
cluster := "eurotransit"
ctx     := "kind-eurotransit"

# local dev image registry (mirrors ACR locally; see platform/kind-registry/)
reg_name       := "kind-registry"
reg_port       := "5001"
local_registry := "localhost:5001"
# app repo (sibling checkout) that holds the service Dockerfiles
app_repo       := "../capstone-application-g03"
image_prefix   := "eurotransit"
img_tag        := "dev"
services       := "catalog orders inventory payments notifications"

# default recipe: list everything
default:
    @just --list

# ── cluster lifecycle ──────────────────────────────────────────────────────

# create the local kind cluster from bootstrap/kind-config.yaml
cluster-up:
    kind create cluster --config bootstrap/kind-config.yaml

# delete the local kind cluster (DESTROYS all state)
cluster-down:
    kind delete cluster --name {{cluster}}

# is the cluster on? show nodes
cluster-status:
    kubectl --context {{ctx}} get nodes -o wide

# pause the cluster (stop containers, keep state) to free laptop RAM
cluster-stop:
    docker stop {{cluster}}-control-plane {{cluster}}-worker {{cluster}}-worker2

# resume after `cluster-stop`
cluster-start:
    docker start {{cluster}}-control-plane {{cluster}}-worker {{cluster}}-worker2

# ── local image registry (mirrors ACR for dev) ─────────────────────────────

# start the local registry + wire it into the kind nodes (run AFTER `cluster-up`)
registry-up:
    #!/usr/bin/env bash
    set -euo pipefail
    # 1. start the registry container (create if missing, else ensure running)
    if [ -z "$(docker ps -aq -f name=^{{reg_name}}$)" ]; then
      docker run -d --restart=always -p 127.0.0.1:{{reg_port}}:5000 --network bridge --name {{reg_name}} registry:2
    else
      docker start {{reg_name}} >/dev/null
    fi
    # 2. point each kind node's containerd at the registry (localhost:5001 -> kind-registry:5000)
    for node in $(kind get nodes --name {{cluster}}); do
      docker exec "$node" mkdir -p /etc/containerd/certs.d/localhost:{{reg_port}}
      echo '[host."http://{{reg_name}}:5000"]' | docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/localhost:{{reg_port}}/hosts.toml
    done
    # 3. connect the registry to the kind network so the nodes can reach it
    docker network connect kind {{reg_name}} >/dev/null 2>&1 || true
    # 4. advertise the registry (standard kind ConfigMap)
    kubectl --context {{ctx}} apply -f platform/kind-registry/local-registry-hosting.yaml

# build the 5 services (native arch) and push them to the local registry as :dev
images-kind:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in {{services}}; do
      img="{{local_registry}}/{{image_prefix}}/$s:{{img_tag}}"
      echo "== build + push $img (native $(uname -m)) =="
      docker build -t "$img" "{{app_repo}}/services/$s"
      docker push "$img"
    done

# ── platform: traefik (ingress controller) ─────────────────────────────────

# install/upgrade Traefik for LOCAL kind (base + kind overlay)
traefik-install:
    helm repo add traefik https://traefik.github.io/charts
    helm repo update traefik
    helm upgrade --install traefik traefik/traefik \
      --version 41.0.0 \
      --namespace traefik --create-namespace \
      -f platform/traefik/values.yaml \
      -f platform/traefik/values-kind.yaml

# verify Traefik: pod placement (must be control-plane), ingressclass, listening on :80
traefik-verify:
    kubectl --context {{ctx}} -n traefik get pods -o wide
    kubectl --context {{ctx}} get ingressclass
    @curl -s -o /dev/null -w "traefik on :80 -> HTTP %{http_code} (404 = up, no route yet)\n" http://localhost/ || true

# ── platform: cert-manager (automatic TLS) ─────────────────────────────────

# install/upgrade cert-manager (WITH its CRDs), then apply the local self-signed ClusterIssuer
certmanager-install:
    helm repo add jetstack https://charts.jetstack.io
    helm repo update jetstack
    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --version v1.20.3 \
      --set crds.enabled=true \
      --wait
    kubectl --context {{ctx}} apply -f platform/cert-manager/clusterissuer-kind.yaml

# verify cert-manager: 3 pods Running + the selfsigned ClusterIssuer is READY=True
certmanager-verify:
    kubectl --context {{ctx}} -n cert-manager get pods
    kubectl --context {{ctx}} get clusterissuer

# ── platform: data & eventing operators (Step 3) ───────────────────────────

# install/upgrade the CloudNativePG operator (per-service DB Cluster CRs ship with the app chart)
cnpg-install:
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update cnpg
    helm upgrade --install cnpg cnpg/cloudnative-pg \
      --namespace cnpg-system --create-namespace \
      --version 0.28.3 \
      --wait

# install/upgrade the Strimzi (Kafka) operator into the kafka namespace
strimzi-install:
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update strimzi
    helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
      --namespace kafka --create-namespace \
      --version 1.1.0 \
      --wait

# apply the LOCAL single-node Kafka cluster + topics (kind only; prod uses kafka.yaml + kafka-topics.yaml)
kafka-kind-apply:
    kubectl --context {{ctx}} apply -f platform/strimzi/kafka-kind.yaml

# verify Step 3: CRDs present, operators Running, Kafka cluster + topics Ready
data-verify:
    @kubectl --context {{ctx}} get crd | grep -E "cnpg|strimzi" || true
    kubectl --context {{ctx}} -n cnpg-system get pods
    kubectl --context {{ctx}} -n kafka get pods
    kubectl --context {{ctx}} -n kafka get kafka,kafkanodepool,kafkatopic

# ── application (local helm deploy on kind) ────────────────────────────────

# deploy/upgrade the app chart on kind (base + kind overlay) into the eurotransit namespace
app-deploy:
    helm upgrade --install eurotransit deploy/charts/eurotransit \
      --namespace eurotransit --create-namespace \
      -f deploy/charts/eurotransit/values.yaml \
      -f deploy/charts/eurotransit/values-kind.yaml

# verify the app: service pods, the CNPG databases, ingress + TLS certificate
app-verify:
    kubectl --context {{ctx}} -n eurotransit get pods -o wide
    kubectl --context {{ctx}} -n eurotransit get cluster
    kubectl --context {{ctx}} -n eurotransit get ingress,certificate

# ── one-shot bootstrap ─────────────────────────────────────────────────────

# full local bootstrap from scratch: cluster + registry + platform (Steps 1-3)
bootstrap-kind: cluster-up registry-up traefik-install certmanager-install cnpg-install strimzi-install kafka-kind-apply
    @echo ">> kind cluster + registry + platform ready."
    @echo ">> next:  just images-kind   &&   just app-deploy"

# ── platform: next steps (add recipes as we install each) ───────────────────
# sealedsecrets-install: ...   (Step 4)
# observability-install: ...   (Step 5)
# argocd-install:        ...   (Step 6)