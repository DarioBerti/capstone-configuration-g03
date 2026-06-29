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
services       := "catalog orders inventory payments notifications users"

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

# build the services + the debug SPA (native arch) and push them to the local registry as :dev
images-kind:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in {{services}}; do
      img="{{local_registry}}/{{image_prefix}}/$s:{{img_tag}}"
      echo "== build + push $img (native $(uname -m)) =="
      docker build -t "$img" "{{app_repo}}/services/$s"
      docker push "$img"
    done
    # debug SPA: VITE_KEYCLOAK_URL is baked at build time -> point it at the kind Keycloak ingress host
    fe="{{local_registry}}/{{image_prefix}}/frontend:{{img_tag}}"
    echo "== build + push $fe (native $(uname -m)) =="
    docker build --build-arg VITE_KEYCLOAK_URL=https://auth.localhost -t "$fe" "{{app_repo}}/frontend"
    docker push "$fe"

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

# install the Keycloak Operator (CRDs + controller) into the eurotransit namespace. MUST run before
# `app-deploy` so the chart's Keycloak/KeycloakRealmImport CRs have their CRDs. -k uses the kustomize base.
keycloak-install:
    kubectl --context {{ctx}} create namespace eurotransit --dry-run=client -o yaml | kubectl --context {{ctx}} apply -f -
    kubectl --context {{ctx}} apply -k platform/keycloak/operator
    @echo ">> waiting for the Keycloak CRDs to register ..."
    kubectl --context {{ctx}} wait --for=condition=established --timeout=120s \
      crd/keycloaks.k8s.keycloak.org crd/keycloakrealmimports.k8s.keycloak.org

# verify Keycloak: operator running, the Keycloak CR + realm import reconciled, login ingress present
keycloak-verify:
    kubectl --context {{ctx}} -n eurotransit get pods -l app.kubernetes.io/name=keycloak-operator
    kubectl --context {{ctx}} -n eurotransit get keycloak,keycloakrealmimport
    kubectl --context {{ctx}} -n eurotransit get ingress keycloak

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

# ── local debugging (run a service in your IDE against the cluster) ─────────

# tunnel a service's CNPG primary DB to localhost + print the creds for your IDE run config.
# Usage: `just db-forward orders`  (or `just db-forward payments 5433` to pick a local port).
# Set in IntelliJ: profile `postgres`, then the DB_* env vars printed below. Ctrl-C to stop.
db-forward service local_port="5432":
    #!/usr/bin/env bash
    set -euo pipefail
    secret="{{service}}-db-app"
    echo "== {{service}} DB — IntelliJ run config (Active profiles: postgres) =="
    echo "  DB_HOST = localhost"
    echo "  DB_PORT = {{local_port}}"
    echo "  DB_NAME = $(kubectl --context {{ctx}} -n eurotransit get secret "$secret" -o jsonpath='{.data.dbname}'   | base64 -d)"
    echo "  DB_USER = $(kubectl --context {{ctx}} -n eurotransit get secret "$secret" -o jsonpath='{.data.username}' | base64 -d)"
    echo "  DB_PASS = $(kubectl --context {{ctx}} -n eurotransit get secret "$secret" -o jsonpath='{.data.password}' | base64 -d)"
    echo
    echo ">> forwarding svc/{{service}}-db-rw -> localhost:{{local_port}} (Ctrl-C to stop) ..."
    kubectl --context {{ctx}} -n eurotransit port-forward svc/{{service}}-db-rw {{local_port}}:5432

# tunnel the Strimzi Kafka broker to localhost for IDE debugging of event paths.
# Usage: `just kafka-forward`  then set KAFKA_BOOTSTRAP=localhost:9092 in your run config. Ctrl-C to stop.
kafka-forward local_port="9092":
    @echo ">> set KAFKA_BOOTSTRAP=localhost:{{local_port}} in your IDE run config"
    @echo ">> forwarding svc/eurotransit-kafka-bootstrap -> localhost:{{local_port}} (Ctrl-C to stop) ..."
    kubectl --context {{ctx}} -n kafka port-forward svc/eurotransit-kafka-bootstrap {{local_port}}:9092

# ── whole-app local dev (run all 6 services in your IDE, data layer in kind) ─
# Workflow:  just dev-down   (free the cluster of app pods so they don't fight your local ones)
#            just dev-forward-all   (leave running in a tab — tunnels every DB + Kafka + Keycloak)
#            just dev-env           (prints the IntelliJ env block per service)
#            ...debug in IntelliJ...
#            just dev-up     (redeploy the pods into the cluster when you're done)

# scale the 6 app Deployments to 0 (DB + Kafka keep running) so local JVMs own the work
dev-down:
    kubectl --context {{ctx}} -n eurotransit scale deploy --all --replicas=0
    @echo ">> app pods scaled to 0. CNPG databases + Kafka still running."
    @echo ">> next: just dev-forward-all   (new tab)   then   just dev-env"

# restore the app pods in-cluster (helm reconciles each service back to its declared replicas)
dev-up: app-deploy
    @echo ">> app pods restored in-cluster."

# background a port-forward for every DB (distinct local ports) + Kafka + Keycloak; Ctrl-C stops them all
dev-forward-all:
    #!/usr/bin/env bash
    set -euo pipefail
    pids=()
    cleanup() { echo; echo ">> stopping all port-forwards"; kill "${pids[@]}" 2>/dev/null || true; }
    trap cleanup EXIT INT TERM
    fwd() { # $1=localPort:remotePort  $2=namespace  $3=service
      kubectl --context {{ctx}} -n "$2" port-forward --address 0.0.0.0 "svc/$3" "$1" >/dev/null 2>&1 &
      pids+=($!); echo "  $3 -> localhost:${1%%:*}"
    }
    fwd 5432:5432 eurotransit catalog-db-rw
    fwd 5433:5432 eurotransit orders-db-rw
    fwd 5434:5432 eurotransit inventory-db-rw
    fwd 5435:5432 eurotransit payments-db-rw
    fwd 5436:5432 eurotransit users-db-rw
    fwd 9092:9092 kafka       eurotransit-kafka-bootstrap
    # Keycloak on :8180 so the secured services' default KEYCLOAK_JWK_SET_URI (localhost:8180) resolves
    # locally; the token's real issuer (https://auth.localhost) is matched via KEYCLOAK_ISSUER in dev-env.
    fwd 8180:8080 eurotransit keycloak-service
    echo ">> all forwards up. Leave this tab running; Ctrl-C to stop them all."
    wait

# print the IntelliJ env block per service (Active profiles: postgres); live-reads passwords
dev-env:
    #!/usr/bin/env bash
    set -euo pipefail
    pw() { kubectl --context {{ctx}} -n eurotransit get secret "$1-db-app" -o jsonpath='{.data.password}' | base64 -d; }
    # OIDC for the SECURED resource servers (catalog/orders/inventory/payments/users). The token's `iss`
    # is the operator's fixed hostname (https://auth.localhost); JWKS is fetched from the :8180 Keycloak
    # forward set up by dev-forward-all. notifications is unsecured, so it gets no KC env.
    kc="KEYCLOAK_ISSUER=https://auth.localhost/realms/eurotransit;KEYCLOAK_JWK_SET_URI=http://localhost:8180/realms/eurotransit/protocol/openid-connect/certs"
    echo "SEMICOLON form -> paste into IntelliJ's *inline* Environment variables field (Active profiles: postgres)."
    echo "Using .env files instead? run \`just dev-env-files\` (writes one .env per service). Run dev-forward-all first."
    echo
    echo "=== catalog (SERVER_PORT 8083) ==="
    echo "SERVER_PORT=8083;DB_HOST=localhost;DB_PORT=5432;DB_NAME=catalogdb;DB_USER=catalog;DB_PASS=$(pw catalog);$kc"
    echo
    echo "=== orders (SERVER_PORT 8080) ==="
    echo "SERVER_PORT=8080;DB_HOST=localhost;DB_PORT=5433;DB_NAME=ordersdb;DB_USER=orders;DB_PASS=$(pw orders);KAFKA_BOOTSTRAP=localhost:9092;INVENTORY_BASE_URL=http://localhost:8081;PAYMENTS_BASE_URL=http://localhost:8082;$kc"
    echo
    echo "=== inventory (SERVER_PORT 8081) ==="
    echo "SERVER_PORT=8081;DB_HOST=localhost;DB_PORT=5434;DB_NAME=inventorydb;DB_USER=inventory;DB_PASS=$(pw inventory);KAFKA_BOOTSTRAP=localhost:9092;$kc"
    echo
    echo "=== payments (SERVER_PORT 8082) ==="
    echo "SERVER_PORT=8082;DB_HOST=localhost;DB_PORT=5435;DB_NAME=paymentsdb;DB_USER=payments;DB_PASS=$(pw payments);KAFKA_BOOTSTRAP=localhost:9092;$kc"
    echo
    echo "=== users (SERVER_PORT 8085) ==="
    echo "SERVER_PORT=8085;DB_HOST=localhost;DB_PORT=5436;DB_NAME=usersdb;DB_USER=users;DB_PASS=$(pw users);$kc"
    echo
    echo "=== notifications (SERVER_PORT 8084, no DB) ==="
    echo "SERVER_PORT=8084;KAFKA_BOOTSTRAP=localhost:9092"

# write one NEWLINE-format .env per service to services/<svc>/.env (gitignored). Point each IDE run config at it.
dev-env-files:
    #!/usr/bin/env bash
    set -euo pipefail
    pw() { kubectl --context {{ctx}} -n eurotransit get secret "$1-db-app" -o jsonpath='{.data.password}' | base64 -d; }
    emit() { # $1=service, rest=KEY=VALUE lines
      local svc="$1"; shift
      local f="{{app_repo}}/services/$svc/.env"
      : > "$f"; for kv in "$@"; do echo "$kv" >> "$f"; done
      echo "  wrote $f"
    }
    # OIDC for the SECURED resource servers (see dev-env). JWKS comes from the :8180 Keycloak forward;
    # the token's real issuer (https://auth.localhost) is matched via KEYCLOAK_ISSUER. notifications omits it.
    KC_ISS="KEYCLOAK_ISSUER=https://auth.localhost/realms/eurotransit"
    KC_JWK="KEYCLOAK_JWK_SET_URI=http://localhost:8180/realms/eurotransit/protocol/openid-connect/certs"
    emit catalog       SERVER_PORT=8083 DB_HOST=localhost DB_PORT=5432 DB_NAME=catalogdb   DB_USER=catalog   "DB_PASS=$(pw catalog)"   "$KC_ISS" "$KC_JWK"
    emit orders        SERVER_PORT=8080 DB_HOST=localhost DB_PORT=5433 DB_NAME=ordersdb    DB_USER=orders    "DB_PASS=$(pw orders)"    KAFKA_BOOTSTRAP=localhost:9092 INVENTORY_BASE_URL=http://localhost:8081 PAYMENTS_BASE_URL=http://localhost:8082 "$KC_ISS" "$KC_JWK"
    emit inventory     SERVER_PORT=8081 DB_HOST=localhost DB_PORT=5434 DB_NAME=inventorydb DB_USER=inventory "DB_PASS=$(pw inventory)" KAFKA_BOOTSTRAP=localhost:9092 "$KC_ISS" "$KC_JWK"
    emit payments      SERVER_PORT=8082 DB_HOST=localhost DB_PORT=5435 DB_NAME=paymentsdb  DB_USER=payments  "DB_PASS=$(pw payments)"  KAFKA_BOOTSTRAP=localhost:9092 "$KC_ISS" "$KC_JWK"
    emit users         SERVER_PORT=8085 DB_HOST=localhost DB_PORT=5436 DB_NAME=usersdb     DB_USER=users     "DB_PASS=$(pw users)"     "$KC_ISS" "$KC_JWK"
    emit notifications SERVER_PORT=8084 KAFKA_BOOTSTRAP=localhost:9092
    echo ">> set Active profiles: postgres in each run config. These files are gitignored (.env)."

# ── one-shot bootstrap ─────────────────────────────────────────────────────

# full local bootstrap from scratch: cluster + registry + platform (Steps 1-3) + Keycloak operator
bootstrap-kind: cluster-up registry-up traefik-install certmanager-install cnpg-install strimzi-install kafka-kind-apply keycloak-install
    @echo ">> kind cluster + registry + platform + Keycloak operator ready."
    @echo ">> next:  just images-kind   &&   just app-deploy"

# ── platform: observability (Step 5) ───────────────────────────────────────
# NB: pin --version <verified> on the helm installs below for reproducibility (the recipes above do);
# left unpinned here so a stale pin can't silently break the install — verify the latest stable first.

# install/upgrade the kube-prometheus-stack. Release name MUST be `kube-prometheus-stack` so its
# serviceMonitorSelector/ruleSelector (release: <name>) adopts our CRs (values.yaml observability.prometheusRelease).
kube-prometheus-install:
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update prometheus-community
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring --create-namespace --wait

# deploy the OpenTelemetry Collector gateway + Grafana Tempo, then the dashboards-as-code ConfigMaps
observability-install: kube-prometheus-install
    kubectl --context {{ctx}} create namespace observability --dry-run=client -o yaml | kubectl --context {{ctx}} apply -f -
    kubectl --context {{ctx}} apply -f platform/observability/otel-collector.yaml
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update grafana
    helm upgrade --install tempo grafana/tempo \
      --namespace observability --create-namespace \
      -f platform/observability/tempo-values.yaml --wait
    kubectl --context {{ctx}} apply -k platform/observability/dashboards/
    @echo ">> verify: kubectl -n eurotransit get servicemonitor,prometheusrule  (Prometheus UI -> Targets/Rules)"

# verify adoption: our ServiceMonitors/PrometheusRule exist and (best-effort) the stack pods are up
observability-verify:
    kubectl --context {{ctx}} -n eurotransit get servicemonitor,prometheusrule
    kubectl --context {{ctx}} -n monitoring get pods -l release=kube-prometheus-stack
    @echo ">> in the Prometheus UI: Status -> Targets (6 services UP), Status -> Rules (eurotransit-checkout-slo)"

# ── platform: chaos engineering ─────────────────────────────────────────────

# install/upgrade Chaos Mesh (containerd runtime — matches kind/AKS nodes). Experiments are applied by hand.
chaos-install:
    helm repo add chaos-mesh https://charts.chaos-mesh.org
    helm repo update chaos-mesh
    helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
      --namespace chaos-mesh --create-namespace \
      --set chaosDaemon.runtime=containerd \
      --set chaosDaemon.socketPath=/run/containerd/containerd.sock --wait

# ── load generation (k6 money path) ─────────────────────────────────────────

# run the k6 money-path load test. Usage: `just loadtest https://<host> <jwt>` (token optional but the
# secured endpoints need one). Tune with K6_VUS / K6_DURATION env, e.g. `K6_VUS=20 just loadtest <url> <jwt>`.
loadtest base_url token="":
    k6 run -e BASE_URL={{base_url}} -e TOKEN={{token}} \
      -e VUS=${K6_VUS:-10} -e DURATION=${K6_DURATION:-5m} \
      platform/k6/money-path.js

# ── platform: next steps (add recipes as we install each) ───────────────────
# sealedsecrets-install: ...   (Step 4)
# argocd-install:        ...   (Step 6)