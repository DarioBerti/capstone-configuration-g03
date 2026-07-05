# Platform components (installed once per cluster)

These are **shared infrastructure**, not per-app workloads. They are bootstrapped once and
then operate the EuroTransit application declared in `deploy/charts/eurotransit`.

| Component | Namespace | Role |
|---|---|---|
| **Traefik** | `traefik` | North-south ingress + TLS termination; weighted TraefikService = the canary data plane |
| **cert-manager** | `cert-manager` | ACME/Let's Encrypt certificates for the ingress |
| **CloudNativePG operator** | `cnpg-system` | Reconciles per-service PostgreSQL `Cluster` CRs |
| **Strimzi operator** | `kafka` | Reconciles the Kafka cluster + topics for the async pipeline |
| **Debezium (Kafka Connect)** | `kafka` | Log-based CDC: drains each service's outbox off the WAL onto Kafka |
| **Sealed Secrets** | `sealed-secrets` | Decrypts committed `SealedSecret`s into in-cluster Secrets (one canonical Bitnami controller) |
| **Argo CD** | `argocd` | GitOps reconciliation of desired state |
| **Argo Rollouts** | `argo-rollouts` | Progressive delivery controller: SLO-gated canary + blue/green on orders |
| **kube-prometheus-stack** | `monitoring` | Prometheus + Grafana + Alertmanager (RED/USE, SLO alerts) |
| **Tempo / OTel collector** | `observability` | Distributed tracing backend for the money path |
| **Chaos Mesh** | `chaos-mesh` | Controlled failure injection for the chaos experiments |

## Pinned operator versions (reproducibility)

Operators are installed once via Helm with an **explicit** chart version (never `latest`).

| Operator | Chart | Pinned version | Notes |
|---|---|---|---|
| **Strimzi** | `strimzi/strimzi-kafka-operator` | `1.0.0` | verified 2026-06-28; latest stable (≥0.50.1 fixes CVE-2026-27133/27134) |
| **CloudNativePG** | `cnpg/cloudnative-pg` | `1.29.1` | ≥1.25 required for `postgresql.synchronous` (inventory/orders RPO=0); pin with `--version 1.29.1` |
| **Argo Rollouts** | `argo/argo-rollouts` | `2.41.0` (app v1.9.0) | ≥ app v1.7 required for the `--traefik-api-group=traefik.io` flags (Traefik v3) |
| **Sealed Secrets** | `sealed-secrets/sealed-secrets` | `2.18.6` (app v0.37.0) | ONE canonical controller in ns `sealed-secrets` (consolidated from the former `kube-system` duplicate); matches the kubeseal client |

Subdirectories hold the per-component bootstrap config:

```
argocd/          Argo CD Application(s) + Argo CD's own ingress/values + sealed repo creds
strimzi/         Kafka cluster CR + KafkaTopic CRs (order-placed, reserve-seats, reservation-result, ...); kafka-kind.yaml = single-node kind variant; kafka-ui.yaml = dev-only browse console at https://kafka-ui.localhost (`just kafka-ui`, never deployed to AKS)
cert-manager/    ClusterIssuers: clusterissuer.yaml (LE staging+prod, AKS) + clusterissuer-kind.yaml (selfsigned, kind)
traefik/         Traefik install values: values.yaml (base) + values-prod.yaml (LoadBalancer, AKS) + values-kind.yaml (hostPort, kind)
cloudnativepg/   operator install notes (the per-service Cluster CRs live in the app chart)
argo-rollouts/   progressive delivery runbook (install, demo commands, GitOps coexistence, async caveat)
observability/   kube-prometheus-stack values, Tempo/OTel, ServiceMonitors, SLO rules
chaos-mesh/      chaos experiment manifests (one per hypothesis)
sealed-secrets/  controller notes + how to seal a secret
kind-registry/   local dev only: localhost:5001 registry that mirrors ACR for the kind fidelity loop
```

> Secrets live in Git **only** as SealedSecrets. CI updates desired state; Argo CD
> deploys. No `helm install` / `kubectl apply` for application releases.
