# Platform components (installed once per cluster)

These are **shared infrastructure**, not per-app workloads. They are bootstrapped once and
then operate the EuroTransit application declared in `deploy/charts/eurotransit`.

| Component | Namespace | Role | Source lab |
|---|---|---|---|
| **Traefik** | `traefik` | North-south ingress + TLS termination; canary via TraefikService | Lab03 |
| **cert-manager** | `cert-manager` | ACME/Let's Encrypt certificates for the ingress | Lab03 |
| **CloudNativePG operator** | `cnpg-system` | Reconciles per-service PostgreSQL `Cluster` CRs | Lab03 |
| **Strimzi operator** | `kafka` | Reconciles the Kafka cluster + topics for the async pipeline | Capstone |
| **Sealed Secrets** | `kube-system` | Encrypts secrets at rest in Git | Lab04 |
| **Argo CD** | `argocd` | GitOps reconciliation of desired state | Lab04 |
| **kube-prometheus-stack** | `observability` | Prometheus + Grafana + Alertmanager (RED/USE, SLO alerts) | Lab05 |
| **Tempo / OTel collector** | `observability` | Distributed tracing backend for the money path | Lab05 |
| **Chaos Mesh** | `chaos-mesh` | Controlled failure injection for the chaos experiments | Capstone |

## Pinned operator versions (reproducibility)

Operators are installed once via Helm with an **explicit** chart version (never `latest`).

| Operator | Chart | Pinned version | Notes |
|---|---|---|---|
| **Strimzi** | `strimzi/strimzi-kafka-operator` | `1.0.0` | verified 2026-06-28; latest stable (≥0.50.1 fixes CVE-2026-27133/27134) |
| **CloudNativePG** | `cnpg/cloudnative-pg` | `1.29.1` | ≥1.25 required for `postgresql.synchronous` (inventory/orders RPO=0); pin with `--version 1.29.1` |

Subdirectories hold the per-component bootstrap config:

```
argocd/          Argo CD Application(s) + Argo CD's own ingress/values + sealed repo creds
strimzi/         Kafka cluster CR + KafkaTopic CRs (order-placed, reserve-seats, reservation-result, ...); kafka-kind.yaml = single-node kind variant; kafka-ui.yaml = dev-only browse console at https://kafka-ui.localhost (`just kafka-ui`, never deployed to AKS)
cert-manager/    ClusterIssuers: clusterissuer.yaml (LE staging+prod, AKS) + clusterissuer-kind.yaml (selfsigned, kind)
traefik/         Traefik install values: values.yaml (base) + values-prod.yaml (LoadBalancer, AKS) + values-kind.yaml (hostPort, kind)
cloudnativepg/   operator install notes (the per-service Cluster CRs live in the app chart)
observability/   kube-prometheus-stack values, Tempo/OTel, ServiceMonitors, SLO rules
chaos-mesh/      chaos experiment manifests (one per hypothesis)
sealed-secrets/  controller notes + how to seal a secret
kind-registry/   local dev only: localhost:5001 registry that mirrors ACR for the kind fidelity loop
```

> Secrets live in Git **only** as SealedSecrets (Lab04). CI updates desired state; Argo CD
> deploys. No `helm install` / `kubectl apply` for application releases.
