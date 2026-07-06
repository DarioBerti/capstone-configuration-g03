# EuroTransit Marketplace — Configuration repository (g03)

The **declarative half** of a two-repository GitOps model. Where the application repository
(`capstone-application-g03`) answers *"how is the code built?"*, this repository answers *"what must run in
the cluster, and with which guarantees?"*. It contains no compilable code — only the **desired state** of the
system. **Argo CD** reads this repo and makes the cluster identical to what is written here; nobody changes the
cluster by hand.

```
 dev → push to capstone-application-g03 (CODE)
   │   CI: test → build immutable :sha images → push to ACR
   │        └─ bump services.<svc>.image.tag in THIS repo's values.yaml (via a scoped PAT)
   ▼
 capstone-configuration-g03 (DESIRED STATE, here)   ← the single source of truth in Git
   │   Argo CD watches deploy/charts/eurotransit
   ▼
 Kubernetes cluster (continuously reconciled: prune + selfHeal)
```

**CI never talks to the cluster** (a graded criterion): its only power is to commit here. This README is the
canonical **configuration/infrastructure** knowledge base (GitOps, platform, delivery, observability, and the
constraints of our student cluster). The money-path *application* design lives in the app repo's README; the
ultimate source of truth is the manifests themselves.

---

## 1. The system

Six services (`catalog`, `orders`, `inventory`, `payments`, `notifications`, `users`) behind a single Traefik
ingress. Browsing and the booking intake are synchronous REST; the **pay → confirm → capture** money path is a
**fully asynchronous, orchestrated Kafka command/reply saga** (Orders is the coordinator) with a **transactional
outbox drained by Debezium CDC**. Each money-path service owns a dedicated CloudNativePG database. See the app
repo's README for the booking state machine and the end-to-end trace.

## 2. Repository structure

Three zones, each answering a different question:

```
 deploy/charts/eurotransit/   → WHAT runs: the desired app state (one Helm chart)
 platform/                    → WHAT it runs on: components installed once per cluster
 docs/                        → WHY: the team's decisions and graded deliverables (judgment)
```

Everything here is **hand-written — nothing is generated** (no `build/`, no `Chart.lock`; the `helm template`
output that Argo CD applies is ephemeral and never committed). So every line is a defensible choice.

- **`values.yaml` is the control panel** — the one file the team edits to change replicas, HPA thresholds,
  resource tiers, or the replication posture, and the one file CI mutates (image tags only). A single `range`
  over `.Values.services` renders every Deployment + Service from `_workload.tpl`, so there is no duplication.
- **`platform/argocd/eurotransit-application.yaml` is the GitOps contract** — `automated.prune` (delete what
  disappears from Git) + `selfHeal` (undo manual `kubectl`) = Git is the only truth.
- **Design decisions map to precise files**: database-per-service + replication posture →
  `templates/databases.yaml` (CNPG `Cluster` CRs, generated `<db>-app` secret injected into pods — passwords
  never enter Git); deliberate probes / graceful drain / topology spread → `_workload.tpl`; targeted HPA →
  `hpa.yaml` (catalog/orders only); PDBs → `poddisruptionbudgets.yaml`; durable async → `platform/strimzi/`;
  secrets only as **SealedSecrets** → `platform/sealed-secrets/`.

Recommended reading order follows the deploy flow: this README → `platform/` (what it runs on) → the Argo CD
`Application` → `Chart.yaml` → `values.yaml` → `templates/` → `platform/strimzi/` → `docs/`.

## 3. Key design decisions (with rationale)

- **CP on the invariant (CAP/PACELC)** — the never-oversell invariant is chosen consistent-over-available; under
  partition/failover the inventory store blocks writes rather than risk a lost reservation.
- **Never oversell** — an atomic conditional `UPDATE … WHERE available >= :qty` + a DB `CHECK`, not an
  application lock.
- **Effective exactly-once = idempotency** — `UNIQUE(order_id)` (payments) and `UNIQUE(order_id, trip_code)`
  (inventory / order legs) make Kafka's at-least-once delivery safe.
- **Orchestrated async saga** — Orders coordinates via Kafka commands/replies (no cross-service HTTP on the
  money path); the booking is two-phase hold→commit with clean compensations.
- **Transactional outbox + Debezium CDC** — the business change and its event commit atomically; a log-based
  connector publishes them, so there is no in-app relay to lose or duplicate rows.
- **Resilience keyed to symptoms/SLOs** — alerts fire on user-visible symptoms and burn rate, never on CPU.
- **One template, N workloads** — `_workload.tpl` renders every service from `values.yaml`.

## 4. Design per pillar

### A — Distributed & async
The money path is an **orchestrated Kafka command/reply saga** (booking: reserve-on-add → authorize → confirm
every leg → capture once → CONFIRMED; compensations `release-seats` / `cancel-authorization`; a timeout sweeper
re-drives stuck sagas). **Outbox → Kafka via Debezium CDC**: every money-path service has an outbox table;
Debezium (**Strimzi Kafka Connect, 2 replicas**, one connector per service) reads the WAL (CloudNativePG at
`wal_level=logical`) and publishes to the topics. **Per-service DLT** + bounded consumer retry. A crashed
service resumes from the topics (at-least-once + idempotent handlers); Orders is not coupled to downstream
availability. Kafka is **KRaft** (no ZooKeeper), **RF=3 / min.insync.replicas=2**, paired with the producer's
`acks=all`.

### B — Consistency under contention
Two-phase hold→commit with clean compensations. **Replication posture = PACELC made configuration**
(`synchronous` block in `databases.yaml`): `inventory-db` is **synchronous `required`** — a commit waits for
the sync standby, so RPO=0 and the never-oversell invariant survives failover (exercised by the CNPG-failover
chaos). It runs **2 instances** (primary + 1 sync standby): the deliberate Part-2 tradeoff to free a disk slot
on the capped student pool (§6) — the price is that if that single standby is down, writes **block** (consistency
over availability, PACELC PC/EC). `orders-db` is synchronous `preferred` (RPO=0 when healthy, degrades to async
rather than blocking intake); `payments-db` / `catalog-db` / `users-db` are single-instance (Payments'
correctness is idempotency, not replication). **Team posture on PG16/Debezium failover:** logical-replication slots don't fail
over natively on PG16 and we deliberately stay on PG16 — after a CNPG failover the connector recreates the slot
on the new primary; money-path events in the gap self-heal (sweeper re-emits, idempotent handlers replay) and
the only permanent loss is best-effort notifications — an accepted, alerted degradation.

### C — Resilience engineering
- **Edge backpressure** — `@RateLimiter` on the synchronous intake → **429 + Retry-After** under overload
  (controlled refusal, not a queue). Edge only; internal calls are on Kafka.
- **Async resilience** (replaces the retired synchronous breaker/bulkhead/retry): **DLT + bounded consumer
  retry**; bulkhead = separate consumer groups + listener concurrency + separate DB pools; backpressure =
  consumer lag. The **circuit breaker returns only around a real external sync egress** (the PayPal PSP).
- **Kubernetes** — PDBs + topology spread on `criticalPath` services; readiness includes the owned DB, liveness
  is process-only (no cascading restarts); graceful shutdown; targeted HPA (catalog/orders).
- **Constrained-cluster tuning (see §6)** — PriorityClasses for deterministic node-pressure eviction, two-tier
  right-sizing, and the Kafka-broker HA caveat, all forced by the student subscription's ceilings.

### D — Delivery + observability
- **GitOps** — Argo CD reconciles `main` with prune + selfHeal; secrets in Git only as SealedSecrets.
- **Progressive delivery** on the money path via **Argo Rollouts** on `orders`: **canary** (weighted
  `TraefikService`, weights patched at runtime by the controller, never in Git) with a background `AnalysisRun`
  (success-rate, ack p99, Kafka listener failure-rate) → **automatic abort** on a bad analysis; and **blue/green**
  (preview at full capacity, manual atomic selector flip) as the alternative strategy. GitOps coexistence via
  `ignoreDifferences` on the controller-managed weight/selector fields. **Release invariant (async):** canary/
  preview pods share the consumer group, so the HTTP weight governs only intake — the release contract is
  command/reply **schema compatibility between adjacent versions**, watched by the canary-scoped analysis.
- **SLOs / SLIs** — checkout **intake success-rate ≥ 99% / 28d** and **ack p99 ≤ 300ms** on standard
  `http_server_requests_seconds*` (a 429 is not an error); multi-window burn-rate alerts. Because a 202/ack no
  longer means "order completed" after the async cutover, the user-visible SLI is the **saga terminal-ratio**
  `= (confirmed + rejected) / placed` (terminal, *not* confirmed — SOLD_OUT/PAYMENT_DECLINED are correct
  outcomes) plus the `orders_overdue_nonterminal` stuck-order gauge; alert on terminal-ratio < 0.99 and gauge
  > 0, never on the confirmed-ratio. Also alerted: DLT depth, and CDC health (connector not RUNNING / slot
  lost / WAL growing). **Not** alerted (dashboard only): consumer lag, CPU/memory, 429.
- **Tracing** — apps instrument Micrometer → OTLP → OTel Collector (gateway) → Tempo. Since the event producer
  is Debezium (not the app), the W3C context is stored as a `traceparent` column on the outbox row (same tx) and
  mapped to a Kafka header, so one trace spans the CDC hop. Tail sampling at the gateway (keep all errors + slow
  traces, sample the rest). **Cardinality discipline:** templated URIs, aggregated lag (never per-partition),
  panels grouped by service/job (never per-pod).

## 5. Platform components (installed once per cluster)

Shared infrastructure, bootstrapped once, then operating the app declared in `deploy/charts/eurotransit`.

| Component | Namespace | Role |
|---|---|---|
| **Traefik** | `traefik` | North-south ingress + TLS; weighted `TraefikService` = the canary data plane |
| **cert-manager** | `cert-manager` | ACME/Let's Encrypt certificates for the ingress |
| **CloudNativePG operator** | `cnpg-system` | Reconciles the per-service PostgreSQL `Cluster` CRs |
| **Strimzi operator** | `kafka` | Reconciles the Kafka cluster + topics for the async pipeline |
| **Debezium (Kafka Connect)** | `kafka` | Log-based CDC: drains each service's outbox off the WAL onto Kafka |
| **Sealed Secrets** | `sealed-secrets` | Decrypts committed `SealedSecret`s into in-cluster Secrets |
| **Argo CD** | `argocd` | GitOps reconciliation of desired state |
| **Argo Rollouts** | `argo-rollouts` | Progressive delivery: SLO-gated canary + blue/green on `orders` |
| **kube-prometheus-stack** | `monitoring` | Prometheus + Grafana + Alertmanager (RED/USE, SLO alerts) |
| **Tempo / OTel collector** | `observability` | Distributed tracing backend for the money path |
| **Chaos Mesh** | `chaos-mesh` | Controlled failure injection for the chaos experiments |

**Pinned operator versions** (installed via Helm with an explicit chart version, never `latest`) — the exact
matrix lives in [`docs/version-compatibility.md`](docs/version-compatibility.md). Highlights: CloudNativePG
≥ 1.25 is required for `postgresql.synchronous` (inventory/orders RPO=0); Argo Rollouts ≥ v1.7 for the
`--traefik-api-group=traefik.io` flags (Traefik v3); one canonical Sealed Secrets controller.

Per-component bootstrap config lives under `platform/<component>/` (Argo CD `Application`s, Strimzi Kafka +
KafkaTopic CRs, cert-manager `ClusterIssuer`s, Traefik values, observability values/SLO rules, Chaos Mesh
manifests, SealedSecrets notes, and a local kind-registry for the fidelity loop).

## 6. Constraints & tradeoffs of the student subscription

The cluster is a **3× `Standard_B2s_v2`** AKS pool (RG `lab02_g03_group`, cluster `lab_g03_cluster`) capped at
6 vCPU with no 4th node possible — memory- and disk-tight. Several deliberate choices exist only to make the
system behave *predictably* inside those ceilings (full rationale in the design notes folded here):

- **Deterministic node-pressure eviction** — two **PriorityClasses** (`platform/priorityclasses.yaml`):
  `eurotransit-critical` (money path orders/inventory/payments **+ the Kafka brokers**) is evicted last and can
  preempt observability; `eurotransit-platform` (catalog/users/notifications/frontend) is recoverable;
  **observability stays at priority 0 → first victim**. Both are far below `system-cluster-critical`, so
  CNI/DNS/metrics are never preempted. This turned "pods killed at random" under memory pressure into a
  deterministic, defensible order.
- **Two-tier right-sizing** (requests ≈ live RSS, never under; **no CPU limit** — throttling would hurt the ack
  SLO): LIGHT `320Mi/512Mi` (catalog/users/notifications) and CRITICAL `448Mi/640Mi` (money path, covers orders'
  ~422Mi peak); DBs at `192Mi/512Mi`. `orders` HPA `maxReplicas` capped 4→3. Verified live: `MemoryPressure=
  False`, 0 OOM, money path healthy.
- **Kafka HA caveat (disk-constrained)** — the 3 brokers stay **co-located** (no anti-affinity). One-broker-per-
  node is physically impossible: the 3rd node has no free Azure data-disk slot (the 12-disk Part-2 ceiling) and
  is memory-full, so a 3rd broker never schedules there. Consequence: losing the node that holds 2 brokers drops
  the KRaft quorum → operationally mitigated in the node-disruption chaos (kill a node that does **not** hold the
  broker majority). A Pay-As-You-Go disk would re-enable a hard spread.
- **DB right-sizing from live measurement** — memory requests lowered to 192Mi (real use 68–155Mi) to free
  ~800Mi of phantom reservations across the 8 instances without shrinking HA — honest booking is how we make
  room when a 4th node isn't allowed.

Reminder: `az aks stop` at the end of every cluster session (cost; student subscription).

## 7. Chaos experiments (Pillar C proof)

The eight experiments live as individual reports under [`docs/chaos/`](docs/chaos/) (hypothesis → steady state →
method → observation → verdict) and run on the live cluster with the commands in
[`docs/demo-runbook.md`](docs/demo-runbook.md). **7 of 8 were executed on the current AKS cluster (2026-07-06)
and all PASS** — each adapted to the constrained-pool config of §6 (e.g. 2-instance CNPG, 2-replica Debezium,
Kafka co-located on one node) and re-verified live. **07 (canary auto-abort) runs during a live rollout** and is
exercised together with the progressive-delivery demo.

| # | Experiment | Verdict |
|---|---|---|
| 01 | Payments latency injection (async absorbs it as lag, not blocked threads) | ✅ PASS |
| 02 | Inventory pod-kill mid-reservation (idempotent reserve; reconciler reclaims holds) | ✅ PASS |
| 03 | Node disruption (PDB + topology spread; kill a node NOT holding the Kafka broker majority — see §6) | ✅ PASS |
| 04 | Kafka partition (consumer lag drains; no oversell) | ✅ PASS |
| 05 | CloudNativePG primary failover (RPO=0 on inventory; connector recreates the slot) | ✅ PASS |
| 06 | Kafka Connect / Debezium worker kill (CDC resumes; outbox drains) | ✅ PASS |
| 07 | Canary auto-abort (bad AnalysisRun → weight to 0, no human in the loop) | ⏳ runs during a live rollout |
| 08 | Poison message → DLT (bounded retry, then park; no head-of-line block) | ✅ PASS |

## 8. Docs index (graded deliverables)

- [docs/design.md](docs/design.md) — the detailed design/consistency justification: the numbered decisions with rationale + the full four-pillar treatment (this README's §3–§4 are the overview)
- [docs/capstone-dod.md](docs/capstone-dod.md) — Definition of Done across the four pillars
- [docs/slo.md](docs/slo.md) — checkout SLOs/SLIs, error budget, and burn-rate alerting policy
- [docs/version-compatibility.md](docs/version-compatibility.md) — language/platform/cloud version & compatibility matrix
- [docs/agent-threat-model.md](docs/agent-threat-model.md) — non-human-actor blast radius
- [docs/agent-log.md](docs/agent-log.md) — where agent-produced artifacts were wrong and how the team caught them (graded)
- [docs/chaos/](docs/chaos/) — the eight chaos-experiment reports
- [docs/demo-runbook.md](docs/demo-runbook.md) — start-to-shutdown demo runbook + chaos run commands
- [docs/postmortem.md](docs/postmortem.md) — blameless postmortem
- [docs/traccia/FASI_PROGETTO.md](docs/traccia/FASI_PROGETTO.md) — phase-by-phase progress and how the team split the work
- [docs/NOTES.md](docs/NOTES.md) — student-subscription tradeoffs: what we did under the 3×B2s_v2 / 12-disk ceiling vs. what a real/prod environment would change

> This README is the config-side overview; the detailed decision log + per-pillar rationale live in `docs/design.md`,
> and the application-side design and booking money path live in the app repo's README.
