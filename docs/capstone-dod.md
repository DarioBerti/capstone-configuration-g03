# Definition of Done — EuroTransit Capstone (g03)

Team-authored DoD. Each item is short, operational, and checkable. Status: ☐ todo / ☑ done.

> Status snapshot (2026-06-28): Pillars **A, B implemented & tested**; **C** done except live K8s validation
> (cluster) and the explicit graceful-degradation test; **D** has GitOps/CI ✅ but observability + progressive
> delivery remain (Phase 4/5); **Chaos** + **demo** remain (Phase 6). Items still ☐ are the work for the close-out.

## Pillar A — Distributed design & async
- ☑ Service decomposition documented with sync vs async boundaries and a justification each. *(design.md §1-§3 + architecture-flow.md sequence/topology diagrams)*
- ☑ Order pipeline is asynchronous (Kotlin coroutines/Flows): `POST /api/orders` returns
  quickly (202) while reserve/authorize/confirm proceed through Kafka-driven stages. *(OrdersController 202 + outbox; OrderPlacedListener → OrderSaga; OutboxPublisher relay)*
- ☑ Structured concurrency: pipeline runs in a supervised `CoroutineScope` (failure domain). *(OutboxPublisher, OrderRecoverySweeper, ReservationReconciler — SupervisorJob)*
- ☑ Cooperative cancellation on SIGTERM: in-flight work finishes or cancels cleanly; no
  orphaned tasks; no double-processing; readiness flips to "refusing traffic" while draining. *(DisposableBean.destroy → scope.cancel; delay as sole suspension point; chart terminationGracePeriodSeconds 30 + preStop)*
- ☐ Written analysis: where async reduces cost/scaling pressure vs where it does not
  (CPU-bound), referencing blocking-vs-suspending. *(design.md §6 — to complete)*

## Pillar B — Consistency under contention
- ☑ Inventory consistency model chosen and justified in CAP/PACELC terms (what we sacrifice
  in a partition; latency/consistency trade-off without a partition). *(design.md #5 + #4.12 CNPG synchronous replication)*
- ☑ Implemented: atomic conditional reservation + reservation state machine. *(InventoryItemRepository.tryDecrement; Reservation state machine)*
- ☑ Idempotency across the money path (dedup keys); duplicated `order-placed` or retried
  authorize never double-reserves or double-charges; dedup-insert and decrement are in the
  **same** transaction. *(UNIQUE(order_id,product_id) / UNIQUE(order_id); InventoryServiceTest + concurrency tests)*
- ☐ Chaos-proven: "never oversell" holds under duplicate messages and pod kill. *(Phase 6 — chaos #2)*

## Pillar C — Resilience
- ☑ Circuit breaker on Orders → Payments (open/half-open policy + safe fallback). *(Phase 2 #1, 2026-06-25 — programmatic via CircuitBreakerRegistry + PAYMENT_PENDING parking + recovery sweep; PaymentsCircuitBreakerTest + PaymentsGatewayBreakerIntegrationTest)*
- ☑ Bulkheads isolate resource pools; a slow downstream cannot exhaust shared threads/conns. *(Phase 2 #2, 2026-06-26 — separate semaphore bulkheads payments(8)/inventory(16) via GatewayResilience; BulkheadIsolationTest proves saturating Payments leaves Inventory unaffected)*
- ☑ Timeouts + bounded retries with backoff **and jitter** on every remote call. *(Phase 2 #2, 2026-06-26 — connect 2s/read 5s timeouts; retry max-attempts 3, 200ms exp ×2 + jitter, transport-faults-only; RetryBulkheadConfigTest + PaymentsRetryTest + PaymentsRetryIntegrationTest)*
- ☑ Backpressure / load shedding (HTTP 429) under overload instead of unbounded queuing. *(Phase 2 #3, 2026-06-26 — programmatic RateLimiter on the intake `POST /api/orders` via OrdersIntakeRateLimiter → 429 + Retry-After, timeout 0 = no queue; metric orders_intake_shed_total; OrdersIntakeRateLimiterTest)*
- ☐ Graceful degradation: Notifications fully down → checkout still succeeds. *(true by construction — notification events are best-effort/off the money path; needs an explicit test + live validation, Phase 6)*
- ☑ K8s probes deliberate (liveness independent of downstream); PDBs; topology spread; HPA. *(configured in the chart AND validated LIVE on the cluster — see docs/chaos/fase2-6-k8s-validation.md: probes/PDB/topology-spread checked on AKS, a topology-spread issue was found and resolved; agent-log entry recorded)*

## Pillar D — Delivery, observability, proof
- ☑ GitOps: CI builds/tests/publishes immutable images + bumps tags; Argo CD reconciles; CI
  holds **no** cluster credentials. *(Phase 3 — CI green end-to-end, `ci: bump image tags` commits on the config repo; Argo CD Application; secrets = ACR + CONFIG_REPO_PAT only)*
- ☐ Canary (TraefikService weighted) demonstrated on the critical path. *(Phase 5)*
- ☐ Blue/green demonstrated with fast rollback. *(Phase 5)*
- ☐ Discussion of where all-at-once and rolling fit and why not on the critical path. *(Phase 5)*
- ☐ RED dashboards per service; USE/Golden-Signals for infra; symptom-based (burn-rate) alerts. *(Phase 4)*
- ☐ SLOs for checkout: latency SLO + success-rate SLO, with SLIs and an error-budget statement. *(slo.md drafted; wire rules in Phase 4)*
- ☐ Distributed tracing spans the money path (incl. across Kafka). *(OTLP wired in apps; OTel Collector + Tempo pending Phase 4)*

## Chaos experiments
- ☐ All five experiments run as hypotheses (steady state → hypothesis → one failure →
  observe → conclude), each with a report in `docs/chaos/`. *(Phase 6; in-process precursors tagged — see docs/chaos/test-traceability.md)*

## Agentic coding
- ☑ Judgments (decomposition, consistency model, SLOs, failure-mode map, chaos hypotheses,
  postmortem) authored and owned by the team. *(design.md decisions 1-12 + D-A…D-G)*
- ☑ Agent threat-model paragraph written (`docs/agent-threat-model.md`).
- ☑ `docs/agent-log.md` has ≥3 concrete, corrected agent mistakes. *(9+ entries)*

## Deliverables
- ☑ Two repos with history showing GitOps-driven delivery. *(app + config; CI→ACR→tag-bump→Argo CD)*
- ☐ `docs/` complete (DoD, design/consistency, SLOs, chaos reports, postmortem, threat-model,
  agent-log). *(DoD/design/threat-model/agent-log done; SLO rules, chaos reports, postmortem still to fill)*
- ☐ ~5-min recorded demo (link committed) showing running system, dashboards answering
  operational questions, a canary, a blue/green, and an alert firing under injected failure. *(Phase 6)*
