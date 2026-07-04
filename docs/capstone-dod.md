# Definition of Done — EuroTransit Capstone (g03)

Team-authored DoD. Each item is short, operational, and checkable. Status: ☐ todo / ☑ done.
*(Agents scaffold this artifact; the team owns the final tick — especially the pillar-level "acceptable for the rubric?" calls.)*

> **Status snapshot (2026-07-04).** Pillars **A, B implemented & tested**; **C** implemented and re-homed to the
> async model (live K8s validation done; only the explicit graceful-degradation test + the chaos proofs remain);
> **D** — GitOps/CI, observability (RED/SLO/tracing) and progressive delivery (canary + blue/green) are **VALIDATED
> LIVE on AKS (03/07)**. **Remaining = Fase 6**: run the 8 chaos experiments on the cluster, write the postmortem,
> record the ~5-min demo. Money path is a **Kafka command/reply saga + Debezium CDC** (the in-app outbox relay and
> the sync Orders→Payments breaker/bulkhead/retry were retired in the async cutover — see the Pillar C note).
>
> **In flight (branch `async-rework`, not yet merged):** a real **PayPal** PSP behind the mock interface (the home
> of the re-placed egress breaker), **SSE** saga-status streaming, and multi-leg orders + checkout window. Fold the
> corresponding ticks in **after** that branch merges to `main`.

## Pillar A — Distributed design & async
- ☑ Service decomposition documented with sync vs async boundaries and a justification each. *(design.md §1-§4 + DESIGN.md §1-§3 sequence/topology diagrams)*
- ☑ Money path is asynchronous: `POST /api/orders` returns quickly (**202**) and **the entire money path** then
  proceeds as a **Kafka command/reply saga** (no sync Orders→Inventory/Payments call). *(OrdersController 202 + transactional outbox; self-consumed `order-placed` → OrderSaga → OrderStateMachine; SagaReplyListeners; outbox drained by Debezium CDC on all three money-path services — decision 13)*
- ☑ Structured concurrency where it earns it: background work runs supervised and cancels cleanly. *(OrderTimeoutSweeper + inventory ReservationReconciler — `SupervisorJob`/@Scheduled; the coroutine-driven in-app relay is gone, replaced by Debezium CDC)*
- ☑ Cooperative cancellation on SIGTERM: in-flight work finishes or cancels cleanly; no orphaned tasks; no
  double-processing; readiness flips to "refusing traffic" while draining. *(DisposableBean.destroy → scope.cancel; chart terminationGracePeriodSeconds 30 + preStop)*
- ☑ Written analysis: where async reduces cost/scaling pressure vs where it does not (CPU-bound),
  referencing blocking-vs-suspending. *(DESIGN.md §6 + capstone-application-g03/docs/sync-vs-async-resilience.md — the sync→async cutover rationale)*

## Pillar B — Consistency under contention
- ☑ Inventory consistency model chosen and justified in CAP/PACELC terms (what we sacrifice in a partition;
  latency/consistency trade-off without a partition). *(design.md decision 1 + §4-B — CNPG synchronous replication, RPO=0)*
- ☑ Implemented: atomic conditional reservation + reservation state machine. *(InventoryItemRepository conditional decrement; Reservation state machine + `@Version`)*
- ☑ Idempotency across the money path (dedup keys); duplicated `order-placed` or retried authorize never
  double-reserves or double-charges; dedup-insert and decrement are in the **same** transaction.
  *(UNIQUE(order_id, trip_code) / UNIQUE(order_id); InventoryConcurrencyTest + OrderVersionConcurrencyTest)*
- ☐ Chaos-proven: "never oversell" holds under duplicate messages and pod kill. *(Fase 6 — chaos 02 pod-kill + 08 poison/DLT; runbooks ready, execution pending)*

## Pillar C — Resilience

> ⚠️ **Re-homed by the async cutover (decision 13).** The money path no longer makes a sync Orders→Payments call,
> so the circuit breaker / per-dependency bulkhead / inline transport-retry were **retired** with the `gateway/`
> package. Their job — contain a downstream failure, never propagate it — is now done by **temporal decoupling**:
> Kafka buffers the failure as consumer lag, a bounded consumer retry + dead-letter topic isolates a poison
> message, and the timeout sweeper guarantees progress. The breaker **returns around a real external egress**
> (the PayPal PSP on `async-rework`), which is where `@CircuitBreaker/@Retry/@TimeLimiter` belong. **Team call at the
> oral:** present this Pillar A↔C trade explicitly (async resilience) + the egress breaker as its correct home.

- ⤳ **Circuit breaker on the sync Orders → Payments hop — SUPERSEDED (decision 13).** Retired with the sync call it
  protected; replaced by Kafka buffering + DLT + timeout sweeper. To be **re-placed around the PayPal egress** (async-rework). *(history: Phase 2 #1)*
- ☑ **Failure containment without head-of-line blocking: bounded consumer retry + dead-letter topic per service.**
  A poison/exhausted message is parked on `orders-dlt`/`inventory-dlt`/`payments-dlt` instead of stalling the
  partition. *(`DefaultErrorHandler` + `DeadLetterPublishingRecoverer`, FixedBackOff(500ms, 3) in each service's `events/KafkaErrorHandler.kt`)*
- ☑ **Progress guarantee: timeout sweeper re-drives a saga stuck in a non-terminal state** past a deadline; re-drive
  is safe because every command is idempotent. *(`OrderTimeoutSweeper`; OrderTimeoutSweeperTest)*
- ☑ Backpressure / load shedding (HTTP **429 + Retry-After**) under overload instead of unbounded queuing.
  *(`@RateLimiter` on the intake `POST /api/orders`, resilience4j-spring-boot4 2.4.0 + aspectj; over budget → RequestNotPermitted → 429; OrdersIntakeRateLimiterTest)*
- ☑ **Durable broker posture (Kafka is load-bearing for every step).** `acks=all`, idempotent producer; cluster
  `min.insync.replicas≥2`, replication 3, no unclean leader election (3-node `kafka.yaml`). *(a lost event now loses a saga step, not just telemetry)*
- ☑ K8s probes deliberate (liveness independent of downstream); PDBs; topology spread; HPA — configured **and
  validated LIVE on AKS**. *(docs/chaos/fase2-6-k8s-validation.md; a soft-topology-spread co-location was found & recorded — agent-log #16)*
- ☐ Graceful degradation: Notifications fully down → checkout still succeeds. *(true by construction — off the money path; needs an explicit test + live validation, Fase 6)*

## Pillar D — Delivery, observability, proof
- ☑ GitOps: CI builds/tests/publishes immutable images + bumps tags; Argo CD reconciles; CI holds **no** cluster
  credentials. *(CI green end-to-end; `ci: bump image tags` commits on the config repo; Argo CD Applications; secrets = ACR + CONFIG_REPO_PAT only)*
- ☑ Canary on the critical path demonstrated — **Argo Rollouts, SLO-gated, validated LIVE on AKS 03/07** (ramp
  5→25→50→100, AnalysisRun on the Fase-4 SLO queries, **automatic abort** proven). *(D9 = Argo Rollouts, superseding the manual weighted TraefikService; design.md §4-D)*
- ☑ Blue/green demonstrated with fast rollback — Rollouts-native (preview + atomic selector flip + `undo`). *(runbook §7-bis; validated on kind, live path part of the Fase-6 demo)*
- ☑ Discussion of where all-at-once and rolling fit and why not on the critical path. *(design.md §4-D; canary/blue-green only on `orders`, the money-path intake)*
- ☑ RED dashboards per service; USE/Golden-Signals for infra; **symptom-based (burn-rate) alerts**. *(dashboards as-code in Grafana: RED + Kafka + CNPG + Runtime; `eurotransit-checkout-slo` burn-rate rules; never on CPU)*
- ☑ SLOs for checkout: success-rate + ack-latency SLO, with SLIs and an error-budget statement, **plus a saga
  terminal-ratio SLI** (a 202 is not completion). *(design.md §4-D; `checkout_saga:terminal_ratio:rate30m` + `orders_overdue_nonterminal`)*
- ☑ Distributed tracing spans the money path **including across Kafka** — validated live: orders+inventory+notifications
  in ONE Tempo trace. *(traceparent persisted in the outbox row → Debezium header → `listener.observation-enabled`; agent-log #22/#23)*

## Chaos experiments
- ☐ All **8** experiments run as hypotheses (steady state → hypothesis → one failure → observe → conclude), each
  with a report in `docs/chaos/`. *(Fase 6 — runbooks rewritten for the async saga: 01 payments-latency, 02 inventory pod-kill, 03 node disruption, 04 kafka-partition, 05 CNPG failover, 06 Connect-worker kill, 07 canary auto-abort, 08 poison→DLT; execution + Observation sections pending)*

## Agentic coding
- ☑ Judgments (decomposition, consistency model, SLOs, failure-mode map, chaos hypotheses, postmortem) authored
  and owned by the team. *(design.md decisions + §4)*
- ☑ Agent threat-model paragraph written (`docs/agent-threat-model.md`).
- ☑ `docs/agent-log.md` has ≥3 concrete, corrected agent mistakes. *(both repos; being curated to the strongest genuine-error entries)*

## Deliverables
- ☑ Two repos with history showing GitOps-driven delivery. *(app + config; CI→ACR→tag-bump→Argo CD)*
- ☑ **Version/compatibility matrix** captured. *(docs/version-compatibility.md)*
- ☐ `docs/` complete (DoD, design/consistency, SLOs, chaos reports, postmortem, threat-model, agent-log).
  *(DoD/design/SLO/threat-model/agent-log/version-matrix done; **chaos Observation sections + postmortem** still to fill in Fase 6)*
- ☐ ~5-min recorded demo (link committed) showing the running system, dashboards answering operational
  questions, a canary, a blue/green, and an alert firing under injected failure. *(Fase 6)*
