# EuroTransit Marketplace — Configuration repository (g03)

Desired state and platform configuration — the **configuration** half of the two-repository GitOps model. The
**application** repository (`capstone-application-g03`) holds the service source, tests and CI.

> CI (application repo) builds/tests, pushes immutable SHA-tagged images to ACR, and bumps
> `services.<svc>.image.tag` in this repo's `values.yaml`. **Argo CD** watches `deploy/charts/eurotransit` and
> reconciles the cluster to Git. **CI never holds cluster credentials.** Secrets live in Git only as SealedSecrets.

This README is the config-side **knowledge base** (architecture + infrastructure/GitOps/observability/delivery
choices, defensible at the oral). It is one of the three ground documents, with the application repo's `README.md`
and `docs/traccia/FASI_PROGETTO.md` (the phase roadmap). Exact versions live in `docs/version-compatibility.md`.

---

## 1. The system

A cloud-native train-ticket marketplace, graded on **operational behaviour under partial failure**. Six Kotlin 2.2 /
Spring Boot 4 / JDK 21 services (`it.g03.<svc>`): **catalog** (read API, staleness-tolerant), **orders**
(orchestrator of the async Kafka command/reply saga + transactional outbox), **inventory** (the contended resource,
atomic never-oversell, two-phase reserve→confirm), **payments** (idempotent authorize→capture, no double-charge; PSP
**mock** behind an interface), **notifications** (fully async, degrades), **users** (Keycloak-backed profiles).

**Two-repo GitOps model:** `application` (code; CI builds/tests, pushes the SHA-tagged image, bumps `image.tag` here)
+ `configuration` (desired state, reconciled by **Argo CD** on `main`). CI writes only the tag, via a least-privilege
PAT — it never touches the cluster.

## 2. Repository structure

- `deploy/charts/eurotransit/` — the single Helm chart. `values.yaml` is the **control panel** (every template reads
  from it); `values-kind.yaml` is the local overlay, base/`values-prod` for AKS. `templates/` = one file per concern;
  `_workload.tpl` = a reusable Deployment+Service definition (stable **and** canary/green from one source).
- `platform/` — components installed **once** per cluster (not in the chart): traefik, cert-manager, cloudnativepg,
  strimzi (Kafka), **debezium** (Kafka Connect + connectors), **argo-rollouts** (progressive delivery), observability
  (kube-prometheus + OTel Collector + Tempo + dashboards), sealed-secrets, argocd, chaos-mesh, k6.
- `docs/` — team-owned deliverables (this README's companions): DoD, SLOs, agent-log, threat-model, postmortem,
  version matrix, demo runbook, phase roadmap.

## 3. Key design decisions (with rationale)

1. **CAP/PACELC = CP where the invariant lives.** `inventory-db` (and `orders-db`) run **synchronous** CNPG
   replication (`dataDurability=required` for inventory) → **RPO=0**: under partition they block writes rather than
   risk losing a reservation. `catalog`/`payments`-db are single-instance (staleness-tolerant / correctness by
   idempotency).
2. **Never-oversell** = an atomic conditional `UPDATE … WHERE available >= :qty`: the row-lock serializes concurrent
   buyers, the loser sees 0 rows = sold out. No application lock.
3. **No double-charge / exactly-once** = idempotency via `UNIQUE(order_id)` (payments) and `UNIQUE(order_id, trip_code)`
   (inventory) → Kafka's at-least-once is safe (a redelivery is a no-op).
4. **Async command/reply saga on Kafka** instead of synchronous HTTP calls → recoverability + decoupling.
5. **Transactional outbox + Debezium CDC**: the event commits with the state change; **Debezium** reads the outbox
   from the WAL (log-based, no polling — it replaced the old in-app relay thread).
6. **Resilience on symptoms, not resources**: burn-rate alerts on SLOs, never on CPU.
7. **One template, N workloads** (`_workload.tpl`): stable and canary/blue-green share the definition → no drift.

## 4. Design per pillar

### A — Distributed & async (Pillar A)

Money path = an **orchestrated async saga**: `POST /api/orders` (202 Accepted, durable ack) → orders emits
`reserve-seats` → inventory holds the seats and replies `reservation-result` (via **its own** outbox) → orders emits
`authorize-payment` → payments authorizes and replies `payment-result` → orders emits `confirm-seats` +
`capture-payment` → CONFIRMED. Compensations: `release-seats` / `cancel-authorization`. Reply-driven state
`PENDING→RESERVED→AUTHORIZED→CONFIRMED (+REJECTED)`; `OrderTimeoutSweeper` re-drives orders stuck past the deadline.
**Outbox→Kafka via Debezium CDC**: every money-path service has an outbox table; Debezium (Strimzi **Kafka Connect,
3 replicas**, one connector per service) reads the WAL (CNPG `wal_level=logical` + a replication role) and publishes
to the topics. **A DLT per service** + bounded consumer retry. A crashed service resumes by reading the topics
(at-least-once + idempotent handlers); orders is not coupled to downstream availability. *(Full app-side detail: the
application repo `README.md`.)*

### B — Consistency under contention (Pillar B)

Decisions 1–3. Two-phase hold→commit → clean compensations. CNPG synchronous replication keeps the invariant even
under failover (RPO=0). **Team posture (decided 03/07):** Debezium's logical slot does not fail over natively on PG16
and **we stay on PG16** (no PG17 failover-slots): after a CNPG failover the connector recreates the slot on the new
primary; money-path events in the gap self-heal (the sweeper re-emits commands; idempotent handlers re-emit replies),
and the only permanent loss is confined to **best-effort notifications** — an accepted, documented degradation,
watched by the connector-down alert and exercised by chaos #5.

### C — Resilience engineering (Pillar C)

- **Edge backpressure:** `@RateLimiter` on `POST /api/orders` → **429 + Retry-After** under overload (controlled
  refusal, not a queue). Edge-only: internal calls are on Kafka.
- **Async resilience** (replaces the retired sync breaker/bulkhead/retry): **DLT + bounded consumer retry**;
  **bulkhead** = separate consumer groups + listener concurrency + separate DB pools; **backpressure** = consumer
  lag. The **circuit breaker/retry/timeout** return only around a **synchronous external egress** (a real PSP —
  PayPal, on `async-rework`), via `@CircuitBreaker/@Retry/@TimeLimiter` (Boot 4, `resilience4j-spring-boot4` + aspectj).
- **K8s:** PDB + topologySpread on the `criticalPath` services; deliberate probes (readiness = "can I serve now?"
  incl. the owned DB but **not** Kafka; liveness = process only, never a downstream → no cascading restarts); graceful
  shutdown (`terminationGracePeriodSeconds: 30` + preStop); HPA on catalog/orders/users (not inventory/payments —
  their bottleneck is DB/PSP, not CPU). *Prod-grade to evaluate:* **KEDA** to scale consumers on Kafka lag.

### D — Delivery + observability (Pillar D)

- **GitOps:** Argo CD reconciles `main`; drift self-heal + prune (demonstrated); secrets in Git only as SealedSecrets.
- **Progressive delivery** on the money path (`/api/orders`) = **Argo Rollouts** (the policy is in Git, the execution
  is the controller's — every CI tag bump becomes an SLO-gated release):
  - **Canary** (default) = ramp 5→25→50→100 on the weighted `TraefikService` (weights **patched at runtime by the
    controller**, never in Git) + an **AnalysisRun** every 30s with 3 canary-scoped gates: intake success-rate ≥ SLO,
    ack p99 ≤ target, **Kafka listener failure-rate ~0**. A failed analysis → **automatic abort** (weight to 0 =
    instant rollback, no human in the loop). `setCanaryScale: 1` bounds the canary's consumer exposure to 1 pod.
  - **Blue/green** (alternative strategy) = full-capacity preview, in-cluster smoke-test on `orders-preview`, manual
    promotion = an **atomic** flip of the `orders` Service selector (no Traefik).
  - **GitOps coexistence:** weights/selector are runtime controller fields → the Argo CD app ignores them via
    `ignoreDifferences` (managedFieldsManagers) + `RespectIgnoreDifferences`. The Traefik router needs the
    `--traefik-api-group/version=traefik.io` flags (Argo Rollouts ≥ app v1.7).
  - **Async release rule:** canary/preview pods **share the Kafka consumer group** with stable — the HTTP weight only
    governs intake; the release invariant is **command/reply + transition compatibility between adjacent versions**.
    Gate #3 of the analysis watches exactly the canary's consumer side. *(Discussion of where all-at-once & rolling
    fit and why not on the critical path: they don't give per-request/gradual exposure, so the money path uses
    canary + blue/green.)*
- **Metrics/SLO:** Micrometer→Prometheus via a per-service ServiceMonitor. Checkout SLO (`PrometheusRule`):
  **intake success-rate ≥99%/28d** and **ack p99 ≤300ms** on `http_server_requests_seconds*` (a standard metric →
  survives the rework); a **429 is not an error**. **Multi-window burn-rate** alerts (fast 1h/5m ×14.4, slow 6h/30m
  ×6). **Never** alert on CPU/breaker/429. Full SLO/SLI/error-budget statement: `docs/slo.md`.
- **Saga-completion SLI:** the intake SLO only sees the front door — after the async cutover a 202 no longer means
  "order completed" (an order can stall with zero 5xx and zero lag). The user-visible symptom is
  **`checkout_saga:terminal_ratio:rate30m`** = (confirmed+rejected)/placed — **terminal, not confirmed**
  (SOLD_OUT/DECLINED are correct outcomes and must not page). Page on ratio < 0.99 and on
  **`orders_overdue_nonterminal` > 0** (the sweeper gauge catches a total stall even at zero traffic).
- **Signal roles (rule: page only if a human is needed AND users suffer now):**

  | signal | role | alert |
  |---|---|---|
  | intake SLO (success-rate + ack p99) | front-door health | **YES** |
  | saga terminal-ratio + stuck orders | orders that never finish (user-visible) | **YES** |
  | DLT depth (`eurotransit_dlt:depth:sum`) | orders failed for good, no self-heal | **YES** |
  | CDC: connector not RUNNING / slot lost-inactive-WAL growing | publish pipeline stalled (silent) | **YES** |
  | consumer lag (`kafka_consumergroup_lag`) | diagnostic: self-drains | NO — dashboard |
  | CPU/memory/429/Debezium lag | cause or by-design behaviour | NO — dashboard |

- **Tracing:** apps instrumented (Micrometer→OTLP) → **OTel Collector** (gateway, `tail_sampling`: keep all
  error/slow traces, 10% of the rest) → **Tempo**. Because the producer is **Debezium, not the KafkaTemplate**, the
  W3C context is saved as the outbox row's `traceparent` column (same tx) and mapped to a Kafka header; consumers
  continue it via `spring.kafka.listener.observation-enabled`. ECS JSON logs carry traceId/spanId (log↔trace by-id;
  Loki not installed). Exemplars link a metric point to its trace in Tempo.
- **Cardinality discipline:** `uri` stays templated (never raw ids); lag aggregated `by (consumergroup)`/`by (topic)`,
  never per-partition; panels grouped by service/job, never by `pod` (canary/HPA churn names); identity labels
  (`pod`/`instance`) are **never** dropped on app monitors (dropping them corrupts multi-replica series).

## 5. Platform components (installed once per cluster)

Shared infrastructure, not per-app workloads. Pinned versions: `docs/version-compatibility.md` (rule: never `latest`).

| Component | Namespace | Role |
|---|---|---|
| **Traefik** | `traefik` | north-south ingress + TLS; weighted `TraefikService` = the canary data plane |
| **cert-manager** | `cert-manager` | ACME/Let's Encrypt certificates for the ingress |
| **CloudNativePG operator** | `cnpg-system` | reconciles the per-service PostgreSQL `Cluster` CRs |
| **Strimzi operator** | `kafka` | reconciles the Kafka cluster (KRaft) + topics for the async pipeline |
| **Debezium (Kafka Connect)** | `kafka` | log-based CDC: drains each service's outbox off the WAL onto Kafka |
| **Sealed Secrets** | `kube-system` | encrypts secrets at rest in Git |
| **Argo CD** | `argocd` | GitOps reconciliation of desired state |
| **Argo Rollouts** | `argo-rollouts` | progressive delivery controller: SLO-gated canary + blue/green on orders |
| **kube-prometheus-stack** | `monitoring` | Prometheus + Grafana + Alertmanager (RED/USE, SLO alerts) |
| **Tempo / OTel Collector** | `observability` | distributed-tracing backend for the money path |
| **Chaos Mesh** | `chaos-mesh` | controlled failure injection for the chaos experiments |
| **Keycloak** | `eurotransit` | OIDC: realm `eurotransit`, client `eurotransit-frontend` (public SPA) |

## 6. Chaos experiments (Pillar C proof)

Resilience that hasn't been tested is a hypothesis, not a property. Each experiment follows the scientific method:
**steady state (SLIs) → hypothesis → inject one failure → observe (our own dashboards) → conclude**. Manifests:
`platform/chaos-mesh/`; operational run commands: `docs/demo-runbook.md §8`. Experiments **1–5 are the capstone
minimum**; 6–8 cover what the async architecture newly depends on. Live run + Observation/verdict per experiment =
Fase 6 (the two `⬜` items below are filled during the live session).

| # | Experiment | Failure injected | Steady state (SLI) | Hypothesis it proves |
|---|---|---|---|---|
| 08 | poison-message → DLT | non-JSON on a command topic | DLT depth = 0, saga terminal-ratio ~1 | bounded retry → per-service DLT; the partition is never head-of-line blocked |
| 02 | inventory pod-kill | kill one inventory replica mid-reservation | never-oversell holds, seats consistent | idempotency + at-least-once redelivery ⇒ no oversell / double-charge |
| 01 | payments latency | slow the payments consumer | ack p99 steady, Catalog healthy | a slow consumer becomes lag + a sweeper re-drive, not user-visible errors |
| 06 | Connect-worker kill | kill a Kafka Connect worker | CDC keeps publishing | the CDC (now the only outbox→Kafka path) is HA across 3 workers |
| 04 | Kafka partition | partition Orders ↔ Kafka | saga resumes on heal, nothing lost/dup | **the central one**: a Kafka outage delays the saga, never corrupts it |
| 05 | CNPG primary failover | kill the inventory-db primary | RPO=0, checkout recovers within RTO | sync replication loses nothing **and** Debezium CDC resumes (best-effort notifications may drop — accepted) |
| 03 | node / AZ disruption | drain/disrupt a node | money path stays available | PDBs + topology spread keep the critical path up |
| 07 | canary auto-abort | inject latency on the canary→DB path during a rollout | stable never promoted, never suffers | chaos on a bad canary → Argo Rollouts aborts on the SLO gates (Fase 5 ✕ 6; postmortem/demo candidate) |

Run order for the live session: 08 → 02 → 01 → 06 → 04 → 05 → 03 → 07 (07 needs a rollout in flight), one at a time,
with k6 load always on. A **live K8s validation** on AKS already checked probes/PDB/topology-spread and surfaced a
soft-topology-spread co-location (recorded in `docs/agent-log.md`); that finding and the per-experiment Observations
are consolidated here as the live session proceeds.

## 7. Docs index (surviving deliverables)

- `README.md` (this file) — architecture + infra/GitOps/observability/delivery knowledge base
- `docs/traccia/FASI_PROGETTO.md` — phase-by-phase roadmap (the third ground document)
- `docs/capstone-dod.md` — Definition of Done
- `docs/slo.md` — SLO/SLI definitions + error budget
- `docs/agent-log.md` — where agent-produced artifacts were wrong (graded)
- `docs/agent-threat-model.md` — non-human-actor blast radius (least privilege, review gate, worst case)
- `docs/demo-runbook.md` — start-to-shutdown runbook for the oral demo (incl. chaos run commands)
- `docs/postmortem.md` — blameless postmortem of the injected incident
- `docs/version-compatibility.md` — versions & compatibility matrix
- Application-side design (services, layers, money path, schema): the **application repo `README.md`**
