# Chaos Mesh experiments

One manifest per hypothesis. Each experiment follows the scientific method: define steady
state (the SLIs), state a hypothesis, inject **one** failure, observe, conclude. The filled
report (the graded "chaos-proven" evidence) lives in the matching `docs/chaos/0X-*.md`.

| # | Manifest | Kind | Targets | Runbook |
|---|----------|------|---------|---------|
| 01 | `01-payments-latency.yaml` | `NetworkChaos` delay | Payments ↔ Kafka | slow consumer = lag, not errors (`docs/chaos/01-payments-latency.md`) |
| 02 | `02-inventory-podkill.yaml` | `PodChaos` pod-kill | one Inventory pod | never-oversell under redelivery (`docs/chaos/02-inventory-podkill.md`) |
| 03 | `03-node-disruption.yaml` | `kubectl drain` (documented) | one node | PDB + topology spread (`docs/chaos/03-node-disruption.md`) |
| 04 | `04-kafka-partition.yaml` | `NetworkChaos` partition | Orders ↔ Kafka | **central**: outage = delay, never corruption (`docs/chaos/04-kafka-partition.md`) |
| 05 | `05-pg-failover.yaml` | `PodChaos` pod-kill | inventory-db primary | RPO=0 **+ CDC resumes** (`docs/chaos/05-pg-failover.md`) |
| 06 | `06-connect-worker-kill.yaml` | `PodChaos` pod-kill | one Connect worker (of 2, ns `kafka`) | Debezium CDC HA (`docs/chaos/06-connect-worker-kill.md`) |
| 07 | `07-canary-auto-abort.yaml` | `NetworkChaos` delay | canary pods → orders-db | Rollouts auto-abort on the SLO gates (`docs/chaos/07-canary-auto-abort.md`) |
| 08 | *(no manifest — one `kafka-console-producer` command)* | poison record | `reserve-seats` topic | bounded retry → DLT (`docs/chaos/08-poison-message-dlt.md`) |

## Safety model — read before running

- **Manual only, never GitOps.** These files live under `platform/` on purpose: Argo CD reconciles only
  `deploy/charts/`, so nothing here ever auto-applies. You apply one experiment by hand, observe, delete it.
- **One variable at a time.** Run a single experiment under steady load (k6), never two at once — a chaos
  result you can't attribute to one cause is worthless.
- **Bounded blast radius.** The time-based experiments (01, 04, 07) carry a `duration:` and auto-revert even
  if you forget the `kubectl delete`. The pod-kills (02, 05, 06) are one-shot and the controllers self-heal.
- **Experiment 07 needs a per-release label.** The canary pods are only distinguishable by the canary
  ReplicaSet's `rollouts-pod-template-hash` — substitute the `REPLACE_WITH_CANARY_HASH` placeholder while the
  ramp is live (the manifest header has the one-liner). Never apply it with the placeholder unsubstituted:
  the selector then matches nothing (fail-safe, but the run is void).
- **Experiment 03 is a `kubectl drain`,** not a CR: vanilla Chaos Mesh can't evict a managed AKS node, and a
  drain is precisely the voluntary-eviction path PDBs govern. The file documents the exact commands. On the
  3× B2s_v2 / 6-vCPU pool an *involuntary* node loss can leave pods `Pending` (a documented quota finding) —
  prefer the drain for the demo.

## Prerequisites

1. **Install Chaos Mesh** (once, platform-level; pin the version):
   ```bash
   helm repo add chaos-mesh https://charts.chaos-mesh.org && helm repo update
   kubectl create namespace chaos-mesh
   helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --version <PINNED> \
     --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/containerd/containerd.sock
   ```
   (On AKS the container runtime is containerd — the socket path above matters for `NetworkChaos`/`PodChaos`.)
2. **Steady load** generating money-path traffic (`POST /api/orders`, `GET /api/catalog/products`) so the
   checkout SLIs (`docs/design.md §4-D`) are live and the burn-rate alerts can actually fire — `just loadtest`.
3. **Observability up** (this repo's Phase 4): ServiceMonitors scraped, the checkout-SLO PrometheusRule loaded,
   dashboards available — so each experiment's "Observation" section can be filled with real evidence.

## Run / observe / clean up

```bash
kubectl apply -f platform/chaos-mesh/0X-<name>.yaml      # inject
# ...watch the dashboards / consumer-lag / cnpg status as described in the runbook...
kubectl delete -f platform/chaos-mesh/0X-<name>.yaml     # stop (time-based ones also auto-revert)
```

**Label note:** the manifests select pods by the stable chart label `app.kubernetes.io/name: <service>`
(see `deploy/charts/eurotransit/templates/_helpers.tpl`), Kafka by Strimzi's `strimzi.io/cluster: eurotransit`,
and the Postgres primary by CNPG's `cnpg.io/cluster: inventory-db` + `role: primary`. Verify the CNPG primary
label before experiment 05 (newer operators also expose `cnpg.io/instanceRole: primary`).
