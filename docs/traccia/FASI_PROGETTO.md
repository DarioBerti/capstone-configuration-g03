# EuroTransit — Project phases (where we are, what's left)

Shared **progress map**: where we are, what is done/verified, what remains — and how the team split the work.
Update it when a phase changes state. The high-level **design & implementation choices** now live in the two
repo READMEs; the graded record of caught agent mistakes is in `docs/agent-log.md`.

> **WHERE WE ARE (2026-07-06):** Phases 0–5 **done and validated LIVE on AKS** (first async deploy: money path
> CONFIRMED end-to-end, CDC up, cross-Kafka tracing in Tempo, SLO-gated canary ramp + automatic abort). Phase 4
> CLOSED (incl. #8 exemplar / Tempo datasource). The **booking rework** (PayPal PSP behind a gateway, SSE
> saga-status stream, order-legs + checkout hold window, storefront frontend) is **merged on `main`**.
> **Constrained-cluster tuning done this session:** PriorityClasses (deterministic node-pressure eviction),
> two-tier right-sizing, `orders` HPA 4→3, and the Kafka all-on-one-node HA caveat (see the config README §6).
> Decisions: **D9 = Argo Rollouts**, **PG17 failover-slots = NO** (best-effort notification loss accepted).
> **Chaos (Phase 6): 7 of 8 experiments executed LIVE on AKS (2026-07-06) — all PASS** (01–06, 08), each adapted
> to the constrained-pool config. **Remaining:** 07 (canary auto-abort, run during a live rollout) + the blameless
> postmortem + the ~5-min recorded demo.
> The AKS cluster is **stopped** except during sessions (always `az aks stop` at the end — student subscription).

Legend: ✅ done · 🔄 in progress · ⬜ to do

```text
 Phase 0  Foundations              ✅
 Phase 1  Core money path          ✅   ← 6 services; two-phase booking saga (async Kafka command/reply + outbox)
 Phase 2  Application resilience    🔄   ← edge @RateLimiter (429) + async DLT/retry OK; the PSP breaker lives on PayPal
 Phase 3  Platform on real cluster  ✅   ← verified on AKS; + Debezium (Kafka Connect 2 replicas, CNPG logical)
 Phase 4  Observability             ✅   ← validated LIVE on AKS: lag + CDC + DLT + saga SLI + cross-Kafka tracing E2E
 Phase 5  Progressive delivery      ✅   ← Argo Rollouts validated on AKS: 3-gate ramp + automatic abort
 Phase 6  Chaos + postmortem + demo 🔄   ← 7/8 chaos PASS live on AKS (06/07); remaining: 07 canary + postmortem + demo
```

## Division of labour

- **Koisuji (Mattia Domizio)** — the "secondary track": the oral/graded docs (this file, the two READMEs, DoD,
  agent-log, threat-model, version matrix), comment hygiene, and end-to-end + cluster + chaos verification.
- **Riccardo M.** — frontend + backend (the booking rework: PayPal PSP, SSE saga-status stream,
  order-legs/checkout window, the storefront SPA), merged to `main` when tested.
- **Emanuele Romano, Dario Berti** — supporting work; Dario hosts the GitHub repos.

The team owns every judgment (service decomposition, consistency model, SLO definitions, failure-mode mapping,
chaos hypotheses, the postmortem); agents only produce artifacts, and finding their mistakes is itself graded.

---

## Phase 0 — Foundations ✅
Two GitOps repos (`application` + `configuration`), the service skeletons (Kotlin 2.2 / Boot 4 / JDK 21), a
matrix CI (build + test + push, never any cluster credentials), the `justfile`, and the team `docs/`.

## Phase 1 — Core money path ✅
Domain logic of the 6 services; invariants encoded (never-oversell, no-double-charge, no lost events). The money
path is a two-phase, human-gated **booking** (create DRAFT → add outbound + optional return leg, reserving seats
on-add within a backend-owned checkout window → pay → the saga confirms every held leg and captures once →
CONFIRMED).
- ✅ **Inventory** — atomic conditional `UPDATE` (never-oversell), idempotency, two-phase reserve→confirm.
- ✅ **Payments** — idempotent `authorize→capture` (`UNIQUE(order_id)`) behind a `PaymentGateway`; **mock** and
  **PayPal (Orders v2 sandbox)** providers, selected by `payments.provider`.
- ✅ **Orders** — orchestrator: **async Kafka command/reply saga** (reply-driven `DRAFT→HELD→PAYING→AUTHORIZED→
  CONFIRMED`, multi-leg fan-out/fan-in, capture-once) + **transactional outbox** drained via **Debezium CDC**;
  two sweepers (recover-within-window + give-up-at-window).
- ✅ **Notifications** — fully-async SSE status relay + best-effort mock mail (degrades without failing checkout);
  **Catalog** (read API), **Users** (Keycloak-backed profiles).

## Phase 2 — Application resilience 🔄 (Pillar C — re-placed after the async cutover)
With the async cutover, the **synchronous** breaker/bulkhead/retry were **retired** (there is no sync call). State:
- ✅ **Edge backpressure**: `@RateLimiter` on the synchronous intake → **429 + Retry-After**.
- ✅ **Async resilience**: **per-service DLT** + bounded consumer retry.
- ✅ **The circuit breaker returns around the one real sync egress** — the **PayPal PSP** (`@CircuitBreaker`/
  `@Retry` on the gateway, Boot 4 `resilience4j-spring-boot4` + aspectj starter). The retry uses **exponential
  backoff + jitter** (`ofExponentialRandomBackoff`: base 0.5s ×2, ±50% randomization) so retries after a shared
  PSP blip don't thunder it in lockstep. (The Kafka consumer DLT retry stays a bounded `FixedBackOff(500ms, 3)`
  by design — it's poison-message parking, not a remote call.)
- ⬜ **Candidate prod-grade follow-ups (team decision):** explicit bulkhead = separate consumer groups +
  `listener.concurrency`; **KEDA** consumer autoscaling on Kafka lag (not CPU-HPA).

## Phase 3 — Platform on the real cluster ✅ (verified on AKS)
- ✅ Traefik, cert-manager, **CloudNativePG** (sync replication on inventory/orders → RPO=0), **Strimzi/Kafka**,
  Sealed Secrets, Argo CD **Synced & Healthy** (drift self-heal + prune demonstrated), Let's Encrypt prod TLS.
- ✅ **Debezium CDC**: Strimzi **Kafka Connect (2 replicas, HA)** + one connector per service (Argo-managed) +
  CNPG in **logical replication** (`wal_level=logical`). Replaces the old polling relay.
- ✅ CI → bumps `image.tag` in config (never cluster credentials). Money path verified `→ CONFIRMED`.
- ✅ **Decided (03/07): stay on PG16, no failover-slots.** The logical slot dies with the primary; the money
  path self-heals (sweeper re-emits, idempotent handlers replay) and permanent loss is confined to **best-effort
  notifications** — an accepted, documented degradation. Chaos #5 exercises exactly this posture.

## Phase 4 — Observability ✅ (validated LIVE on AKS — full stack)
> **Live validation** (first async deploy on AKS): money path **CONFIRMED end-to-end** (120 CONFIRMED + 49
> REJECTED=SOLD_OUT: never-oversell live, clean sold-out rejections); Debezium connectors RUNNING; consumer lag
> (exporter), CDC metrics, DLT depth = 0, saga SLI, 4 rule groups loaded; **cross-Kafka trace in Tempo**
> (orders + inventory + notifications in the SAME trace via the outbox→Debezium `traceparent` header, 2 hops).
- ✅ **Metrics + SLO + alerts**: kube-prometheus adopts our ServiceMonitors; the `eurotransit-checkout-slo` rule
  (intake success-rate ≥ 99% + ack p99, multi-window burn-rate; a 429 is not an error; never on CPU).
- ✅ **Dashboards as code** (per-service RED + runtime/golden-signals) loaded in Grafana.
- ✅ **Cross-Kafka tracing**: the producer is **Debezium, not the KafkaTemplate** → the W3C context is stored as
  the `traceparent` outbox column (same tx) and mapped to a Kafka header; consumers use
  `listener.observation-enabled`.
- ✅ **Consumer-lag + DLT + CDC monitoring**: kafka-exporter + PodMonitor; JMX Connect/Debezium metrics with
  alerts (connector not RUNNING / metrics absent / slot lost-inactive / WAL growing); DLT-depth page.
- ✅ **Saga-completion SLI**: `checkout_saga:terminal_ratio:rate30m` (terminal, not confirmed — SOLD_OUT/DECLINED
  are correct outcomes) + the `orders_overdue_nonterminal` sweeper gauge; two page-level alerts.
- ✅ **Cardinality + sampling**: templated URIs, never per-partition/per-pod; tail sampling on the OTel Collector
  gateway (all errors + slow traces at 100%, the rest at 10%).
- ✅ **Correlation last mile**: Tempo as a Grafana datasource + exemplars (metric panel dot → opens the trace);
  ECS logs already carry traceId/spanId (Loki a documented non-goal).

## Phase 5 — Progressive delivery ✅ (Argo Rollouts — validated LIVE on AKS)
> **On AKS**: live Deployment→Rollout migration; a real ramp 5→25→50→100 **gated by the Prometheus analysis**
> (3 gates × 19 Successful measurements under traffic); **automatic abort demonstrated** (weight to 0 with no
> human — on a false-positive NaN, since made NaN-proof).
- ✅ **Mechanics**: `orders` is a `Rollout` (same pod template, `_workload.tpl`); each CI `image.tag` bump →
  automatic ramp on the weighted `TraefikService` (weights moved by the controller, never in Git).
- ✅ **Canary analysis**: a background AnalysisRun on the canary-scoped SLO queries (success-rate, ack p99, Kafka
  listener failure-rate) → a failing analysis is an **automatic abort/rollback**.
- ✅ **Blue/green** as the native alternative strategy (preview + atomic selector flip, manual promotion).
- ✅ **GitOps coexistence**: `ignoreDifferences` (managedFieldsManagers) + `RespectIgnoreDifferences`; controller
  pinned with the `traefik.io` flags.
- ✅ **Release rule (async)**: canary/preview **share the consumer group** → the weight governs only HTTP intake;
  the invariant is command/reply schema compatibility between adjacent versions.

## Phase 6 — Chaos + postmortem + demo 🔄 (7/8 chaos executed & PASS — 07 + postmortem + demo remain)
- ✅ **Runbooks rewritten for async** — **8 experiments** (`docs/chaos/`, manifests in `platform/chaos-mesh/`):
  01 payments-latency (a slow consumer = lag + sweeper, not errors — the breaker's replacement under test);
  02 pod-kill inventory (never-oversell under redelivery); 03 node disruption (kill a node NOT holding the Kafka
  broker majority — see the config README §6); 04 kafka-partition (the central one: outage = delay, never
  corruption); 05 CNPG failover (RPO=0 + CDC resumes; PG16 self-healing posture); 06 kill a Kafka Connect worker
  (CDC HA); 07 chaos on the canary → Rollouts auto-abort (links Phase 5 + 6); 08 poison message → DLT (the core
  Pillar-C claim, proven).
- ✅ **Live execution on AKS (2026-07-06): 7 of 8 run and PASS** (01–06, 08). Each ran one at a time under k6
  load (see `docs/chaos/README.md`), was adapted to the constrained-pool config (2-instance CNPG, 2-replica
  Debezium, Kafka co-located), and its report's Observation/verdict is filled with the live results.
- ⬜ **07 (canary auto-abort)** remains — it needs a rollout in flight, so it runs together with the
  progressive-delivery demo (there is already a paused canary on `orders` to drive).
- ⬜ **Blameless postmortem** (candidate: #07 as a "bad deploy") + a **recorded ~5-min demo** (live system,
  dashboards, canary auto-abort, one alert).

---

## Open decisions
- **Async resilience**: which patterns to re-introduce (explicit bulkhead? KEDA?) — see Phase 2.
- **PayPal**: real PSP vs mock. The gateway + PayPal sandbox provider are merged; `mock` stays the default for
  dev/tests. (The spec is domain-agnostic, so either is defensible; PayPal is the home of the circuit breaker.)
- ~~**D9**: TraefikService vs Argo Rollouts~~ → **CLOSED: Argo Rollouts** (automatic SLO canary analysis).
- ~~**Debezium slot-failover**~~ → **CLOSED: no PG17** — stay on PG16; the sweeper self-heals the money path in
  the gap, the best-effort notification loss is accepted. Chaos #5 demonstrates the posture.
- ~~**Part-2 capacity (12 disk slots saturated)**~~ → **CLOSED**: kept the student subscription (no
  Pay-As-You-Go). The 12-disk ceiling is why the 3 Kafka brokers stay co-located (config README §6) and why the
  cluster tuning leans on right-sizing + PriorityClasses rather than more nodes/disks.

## AKS operational notes (why some "yellow" states are expected)
- **`eurotransit` OutOfSync was cosmetic** — the CNPG operator's mutating webhook fills `.spec` defaults our
  minimal Git manifest doesn't declare; fixed with `ServerSideDiff=true` on the Application (server-side-apply
  dry-run respects field ownership). Verified `Synced`.
- **Turbulent cold-start (~10–15 min).** On `az aks start`, apps can CrashLoop until CNPG accepts connections
  (they start before the DB → Flyway fails → recover on retry), and the HPA/canary can briefly balloon `orders`;
  it converges from idle. Details in `docs/demo-runbook.md §2`. The money path works throughout.
- **Node-pressure is now deterministic** — the PriorityClasses + right-sizing (config README §6) mean that under
  memory pressure observability is evicted first and the money path last; verified `MemoryPressure=False`, 0 OOM.

## Verify locally
```bash
# app repo:   just test-all
# config repo: helm lint ./deploy/charts/eurotransit ; helm template eurotransit ./deploy/charts/eurotransit
```
> Golden rule: **nobody changes the cluster by hand** — change Git, Argo reconciles. Every non-obvious choice
> goes into `docs/` or a README (that is where the grade is won).
</content>
