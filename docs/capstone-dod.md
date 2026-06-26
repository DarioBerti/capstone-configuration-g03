# Definition of Done — EuroTransit Capstone (g03)

Team-authored DoD. Each item is short, operational, and checkable. Status: ☐ todo / ☑ done.

## Pillar A — Distributed design & async
- ☐ Service decomposition documented with sync vs async boundaries and a justification each.
- ☐ Order pipeline is asynchronous (Kotlin coroutines/Flows): `POST /api/orders` returns
  quickly (202) while reserve/authorize/confirm proceed through Kafka-driven stages.
- ☐ Structured concurrency: pipeline runs in a supervised `CoroutineScope` (failure domain).
- ☐ Cooperative cancellation on SIGTERM: in-flight work finishes or cancels cleanly; no
  orphaned tasks; no double-processing; readiness flips to "refusing traffic" while draining.
- ☐ Written analysis: where async reduces cost/scaling pressure vs where it does not
  (CPU-bound), referencing blocking-vs-suspending.

## Pillar B — Consistency under contention
- ☐ Inventory consistency model chosen and justified in CAP/PACELC terms (what we sacrifice
  in a partition; latency/consistency trade-off without a partition).
- ☐ Implemented: atomic conditional reservation + reservation state machine.
- ☐ Idempotency across the money path (dedup keys); duplicated `order-placed` or retried
  authorize never double-reserves or double-charges; dedup-insert and decrement are in the
  **same** transaction.
- ☐ Chaos-proven: "never oversell" holds under duplicate messages and pod kill.

## Pillar C — Resilience
- ☑ Circuit breaker on Orders → Payments (open/half-open policy + safe fallback). *(Phase 2 #1, 2026-06-25 — programmatic via CircuitBreakerRegistry + PAYMENT_PENDING parking + recovery sweep; PaymentsCircuitBreakerTest + PaymentsGatewayBreakerIntegrationTest)*
- ☑ Bulkheads isolate resource pools; a slow downstream cannot exhaust shared threads/conns. *(Phase 2 #2, 2026-06-26 — separate semaphore bulkheads payments(8)/inventory(16) via GatewayResilience; BulkheadIsolationTest proves saturating Payments leaves Inventory unaffected)*
- ☑ Timeouts + bounded retries with backoff **and jitter** on every remote call. *(Phase 2 #2, 2026-06-26 — connect 2s/read 5s timeouts; retry max-attempts 3, 200ms exp ×2 + jitter, transport-faults-only; RetryBulkheadConfigTest + PaymentsRetryTest + PaymentsRetryIntegrationTest)*
- ☑ Backpressure / load shedding (HTTP 429) under overload instead of unbounded queuing. *(Phase 2 #3, 2026-06-26 — programmatic RateLimiter on the intake `POST /api/orders` via OrdersIntakeRateLimiter → 429 + Retry-After, timeout 0 = no queue; metric orders_intake_shed_total; OrdersIntakeRateLimiterTest)*
- ☐ Graceful degradation: Notifications fully down → checkout still succeeds.
- ☐ K8s probes deliberate (liveness independent of downstream); PDBs; topology spread; HPA.

## Pillar D — Delivery, observability, proof
- ☐ GitOps: CI builds/tests/publishes immutable images + bumps tags; Argo CD reconciles; CI
  holds **no** cluster credentials.
- ☐ Canary (TraefikService weighted) demonstrated on the critical path.
- ☐ Blue/green demonstrated with fast rollback.
- ☐ Discussion of where all-at-once and rolling fit and why not on the critical path.
- ☐ RED dashboards per service; USE/Golden-Signals for infra; symptom-based (burn-rate) alerts.
- ☐ SLOs for checkout: latency SLO + success-rate SLO, with SLIs and an error-budget statement.
- ☐ Distributed tracing spans the money path (incl. across Kafka).

## Chaos experiments
- ☐ All five experiments run as hypotheses (steady state → hypothesis → one failure →
  observe → conclude), each with a report in `docs/chaos/`.

## Agentic coding
- ☐ Judgments (decomposition, consistency model, SLOs, failure-mode map, chaos hypotheses,
  postmortem) authored and owned by the team.
- ☐ Agent threat-model paragraph written (`docs/agent-threat-model.md`).
- ☐ `docs/agent-log.md` has ≥3 concrete, corrected agent mistakes.

## Deliverables
- ☐ Two repos with history showing GitOps-driven delivery.
- ☐ `docs/` complete (DoD, design/consistency, SLOs, chaos reports, postmortem, threat-model,
  agent-log).
- ☐ ~5-min recorded demo (link committed) showing running system, dashboards answering
  operational questions, a canary, a blue/green, and an alert firing under injected failure.
