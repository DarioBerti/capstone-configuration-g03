# EuroTransit — Project phases (where we are, what's left)

Shared **progress map**: where we are, what is done/validated, what remains. Update it when a phase changes state.
The high-level **design + implementation choices** live in the two repo `README.md` files (application + configuration);
caught agent mistakes (graded) live in `docs/agent-log.md` (config repo). This document is deliberately **step-oriented**:
the path we followed to build and land the system.

> **WHERE WE ARE (2026-07-04):** Phases 0-5 **done and validated LIVE on AKS** (first async deploy: money path
> CONFIRMED end-to-end, CDC up, cross-Kafka tracing in Tempo, SLO-gated canary ramp + automatic abort). Phase 4
> CLOSED (incl. #8 exemplar/Tempo datasource). Decisions: **D9 = Argo Rollouts**, **PG17 failover-slots = NO**
> (notification loss accepted), **Part-2 capacity** (inventory-db 3→2). **Remaining:** Phase 6 execution (8 chaos
> runbooks ready — Chaos Mesh on AKS + live session + postmortem + demo), Phase 2 re-placements (breaker around the
> real PSP / KEDA, with Riccardo on `async-rework`), secret sealing. AKS cluster **stopped** except during sessions
> (always `az aks stop` at the end).
>
> **In flight (branch `async-rework`, not yet merged):** real PayPal PSP behind the mock interface, SSE saga-status
> stream, multi-leg orders + checkout window, and the reworked SPA (frontend + backend, by Riccardo).

Legend: ✅ done · 🔄 in progress · ⬜ to do

```text
 Phase 0  Foundations             ✅
 Phase 1  Core money path         ✅   ← 6 services; saga now ASYNC Kafka command/reply + outbox
 Phase 2  Resilience              🔄   ← edge @RateLimiter (429) + async DLT/retry OK; breaker/bulkhead to re-place
 Phase 3  Platform on cluster     ✅   ← validated on AKS; + Debezium (Kafka Connect 3 replicas, CNPG logical)
 Phase 4  Observability           ✅   ← VALIDATED LIVE on AKS 03/07: lag+CDC+DLT+saga SLI+cross-Kafka tracing E2E
 Phase 5  Progressive delivery    ✅   ← Argo Rollouts VALIDATED on AKS 03/07: ramp 3 gates×19 ok + automatic abort
 Phase 6  Chaos + postmortem      🔄   ← 8 async runbooks READY; remaining: Chaos Mesh on AKS + live session + demo
```

References: application/configuration `README.md` (design + choices), config README §6 (chaos), `docs/agent-log.md`
(config repo).

---

## Phase 0 — Foundations ✅
Two GitOps repos (`application` + `configuration`), service skeletons (Kotlin 2.2 / Boot 4 / JDK 21), a matrix CI
(build+test+push, never cluster credentials), the `justfile`, and the team `docs/` (design in the READMEs, agent-log,
threat-model).

## Phase 1 — Core money path ✅
Domain logic of the 6 services; invariants encoded (never-oversell, no-double-charge, no lost event).
- ✅ **Inventory** — atomic conditional UPDATE (never-oversell), idempotency, two-phase reserve→confirm.
- ✅ **Payments** — idempotent `authorize→capture` (`UNIQUE(order_id)`), PSP mock behind an interface.
- ✅ **Orders** — orchestrator: **async Kafka command/reply saga** (reply-driven `PENDING→RESERVED→AUTHORIZED→CONFIRMED`)
  + **transactional outbox** drained by **Debezium CDC**; `OrderTimeoutSweeper` re-drives stuck orders.
- ✅ **Catalog** (read API), **Notifications** (fully-async, degrades), **Users** (Keycloak profiles).

## Phase 2 — Application resilience 🔄 (Pillar C — re-homed after the async cutover)
With the async cutover the **synchronous** breaker/bulkhead/retry were **retired** (there is no sync call any more). State:
- ✅ **Edge backpressure**: `@RateLimiter` on `POST /api/orders` → **429 + Retry-After**.
- ✅ **Async resilience**: **a DLT per service** + bounded consumer retry.
- ⬜ **To re-place (team decision):** *bulkhead* = separate consumer groups + `listener.concurrency`/`max.poll.records`;
  *retry* = **exponential backoff + jitter** (avoid a retry storm); *circuit breaker/retry/timeout* only around a
  **synchronous external egress** (e.g. PayPal) via annotations (Boot 4, `resilience4j-spring-boot4` + aspectj starter);
  *consumer autoscaling* = **KEDA** on consumer lag (not CPU-HPA). → depends on the **PayPal** decision and KEDA.

## Phase 3 — Platform on the real cluster ✅ (validated on AKS)
- ✅ Traefik, cert-manager, **CloudNativePG** (sync replication inventory/orders → RPO=0), **Strimzi/Kafka**, Sealed
  Secrets, Argo CD **Synced & Healthy** (drift self-heal + prune demonstrated), TLS Let's Encrypt prod.
- ✅ **Debezium CDC** (async rework): Strimzi **Kafka Connect (3 replicas, HA)** + one connector per service
  (Argo-managed) + CNPG in **logical replication** (`wal_level=logical` + a replication role). Replaces the polling relay.
- ✅ CI → bump `image.tag` on config (never cluster credentials). Money path verified `→ CONFIRMED`.
- ✅ **DECIDED (03/07): stay on PG16, no failover-slots.** The logical slot dies with the primary; the money path
  self-heals (the sweeper re-emits commands, idempotent handlers re-emit replies) and the permanent loss is confined to
  **best-effort notifications** — accepted, documented degradation (README config §4-B). Chaos #5 verifies exactly this
  posture + the connector-down alert.

## Phase 4 — Observability ✅ (VALIDATED LIVE on AKS 03/07 — full stack)
> **Live validation 03/07** (first async deploy on AKS): money path async **CONFIRMED end-to-end** (120 CONFIRMED +
> 49 REJECTED=SOLD_OUT: live never-oversell); Debezium **3 connectors RUNNING**; `kafka_consumergroup_lag`, CDC metrics,
> DLT depth=0, saga SLI, 4 rule groups loaded; **cross-Kafka trace in Tempo**: orders+inventory+notifications in the
> SAME trace (traceparent via outbox→Debezium header, 2 hops). Live fixes: `part_of` label, the **Boot 4** OTLP property,
> NaN-proof gate analysis, Strimzi 1.0.0→**1.1.0** on AKS (Kafka 4.3.0), Keycloak memory right-size. See agent-log.
- ✅ **Metrics+SLO+alerts**: kube-prometheus adopts our ServiceMonitors; `eurotransit-checkout-slo` rule (intake
  success-rate ≥99% + ack p99, multi-window burn-rate; 429 is not an error; never on CPU).
- ✅ **Dashboards as-code** (per-service RED + Runtime/golden-signals) loaded into Grafana.
- ✅ **Capacity fix (verified LIVE 30/06):** CPU requests `100m→50m` → the CNPG standbys schedule; observability + CNPG
  HA **coexist** on the 3× B2s_v2.
- ✅ **Cross-Kafka tracing (VALIDATED live 03/07)**: the producer is **Debezium, not the KafkaTemplate** → the W3C
  context is persisted as the outbox row's `traceparent` column (same tx) and the EventRouter maps it to a Kafka header;
  consumers use `listener.observation-enabled`.
- ✅ **Consumer-lag + DLT + CDC monitoring**: kafka-exporter + PodMonitor; JMX Connect/Debezium with alerts (connector
  not RUNNING / metrics absent / slot lost-inactive-WAL>256Mi); **DLT depth** page.
- ✅ **Saga-completion SLI**: `checkout_saga:terminal_ratio:rate30m` (terminal, not confirmed) + gauge
  `orders_overdue_nonterminal`; saga-SLO alert group; saga row on the RED dashboard.
- ✅ **Cardinality + sampling**: policy in README config §4-D; `tail_sampling` on the Collector gateway (contrib image).
- ✅ **Last-mile correlation (#8, 03/07)**: Tempo = Grafana datasource (pinned uid) + **exemplars** (Prometheus
  `exemplar-storage` + `exemplarTraceIdDestinations`). **Loki = documented non-goal** (ECS logs carry traceId/spanId).

## Phase 5 — Progressive delivery ✅ (Argo Rollouts — VALIDATED LIVE ON AKS 03/07)
> **On AKS**: live Deployment→Rollout migration; first real ramp 5→25→50→100 **gated by the analysis on Prometheus**
> (3 gates × 19 Successful measurements under traffic); **automatic abort demonstrated** (weight to 0 with no human — on
> a NaN false positive, then fixed: the gate is now NaN-proof, agent-log #24-family).
**D9 closed (02/07): Argo Rollouts** replaces the manual weight (that was a "human controller on Grafana" = hand-rolled
delivery infra, same class as the pre-Debezium outbox relay). Detail: README config §4-D.
- ✅ **Mechanics**: `orders` = a `Rollout` CRD (same pod template, `_workload.tpl`); each CI `image.tag` bump → an
  automatic ramp 5→25→50→100 on the weighted `TraefikService` (weights moved by the controller, never in Git).
- ✅ **Canary analysis** (the quality jump): an AnalysisRun in the background on the Phase-4 canary-scoped SLO queries
  (success-rate, ack p99, **Kafka listener failure**) → a failed analysis = **automatic abort/rollback**.
- ✅ **Blue/green** as the alternative strategy (preview + atomic selector flip, manual promotion).
- ✅ **GitOps coexistence**: `ignoreDifferences` (managedFieldsManagers) + `RespectIgnoreDifferences`; controller pinned
  (chart 2.41.0 / app v1.9.0) with the `traefik.io` flags.
- ✅ **Release rule (async)**: canary/preview **share the consumer group** → the weight only governs HTTP intake; the
  invariant = command/reply compatibility between adjacent versions (README config §4-D).

## Phase 6 — Chaos + postmortem + demo 🔄 (runbooks rewritten for async — execution remains)
- ✅ **Runbooks rewritten for async (02/07)** — now **8 experiments** (config README §6, manifests in
  `platform/chaos-mesh/`): 01 payments-latency; 02 inventory pod-kill; 03 node disruption; 04 kafka-partition (**the
  central one**); 05 CNPG failover (RPO=0 **+ CDC resumes** — PG16 self-heals via the sweeper, notification loss
  accepted); 06 kill Kafka Connect worker (CDC HA); 07 chaos on the canary → Rollouts auto-abort (F5×F6, demo/postmortem
  candidate); 08 poison message → DLT (the core Pillar C claim). Test→experiment traceability rewritten on the current tests.
- ⬜ **Live execution on AKS** (team session): run the 8 in order (config README §6), evidence in the Observation
  sections, PASS criteria ticked.
- ⬜ **Blameless postmortem** (candidate: #07 as a "bad deploy") + **recorded demo ~5 min** (live system, dashboards,
  canary auto-abort, an alert).

---

## Open decisions
- **Async resilience**: which patterns to re-introduce (explicit bulkhead? KEDA? breaker around PayPal?) — see Phase 2.
- **PayPal**: real PSP vs mock (the spec is domain-agnostic → a mock is acceptable; PayPal = polish + the breaker's home).
  → **now in progress on `async-rework`** (real PSP behind the mock interface).
- ~~**D9**: TraefikService vs Argo Rollouts~~ → **CLOSED 02/07: Argo Rollouts**.
- ~~**Debezium slot-failover**~~ → **CLOSED 03/07: NO PG17** — stay on PG16; the sweeper self-heals the money path in the
  gap, best-effort notification loss accepted. Chaos #5 demonstrates this posture.
- ~~**Part-2 capacity (12 disks saturated)**~~ → **CLOSED 04/07: Option A** — `inventory-db` 3→2 instances (frees one of
  the 12 disk slots → cold-start converges deterministically; RPO=0 kept, we only lose tolerance to losing the standby).
  Stay on the free Students subscription. + a `wait-for-db` init container to kill the app-before-DB CrashLoop. Verified
  04/07: eurotransit **Synced + Healthy**, inventory 2/2, Kafka 3/3, all green.

## AKS operational notes (04/07) — why some "yellow" states are expected
- **`eurotransit` OutOfSync — RESOLVED (it was cosmetic).** Not the Rollouts fields (already covered by
  `ignoreDifferences`) but the **4 CNPG Clusters**: the CNPG mutating webhook **fills the Cluster `.spec` with defaults**
  our minimal manifest doesn't declare → Argo saw drift → perpetual yellow. **Fix**: annotation
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` on the Application → the server-side-apply dry-run respects
  field ownership. Verified: `eurotransit` → `Synced`.
- **Turbulent cold-start (~10-15 min).** On `az aks start` apps can CrashLoop until the CNPG DB accepts connections
  (they start before the DB → Flyway fails → they recover on retry). The HPA can spike and the canary can auto-start.
  Details/remedies in `docs/demo-runbook.md §2`. The money path works throughout.
- **`inventory-db` at 2/3 on the current pool.** The 3rd instance struggles to join (6 vCPU / 12 saturated disks): the
  concrete symptom of the Part-2 decision. At 2/3 inventory is functional (RPO=0 with 1 sync standby).

## Verify locally
```bash
# app repo:    just test-all
# config repo: helm lint ./deploy/charts/eurotransit ; helm template eurotransit ./deploy/charts/eurotransit
```
> Golden rule: **nobody changes the cluster by hand** — change Git, Argo reconciles. Every non-obvious choice goes in the
> READMEs/`docs/` (that's where the grade is earned).
