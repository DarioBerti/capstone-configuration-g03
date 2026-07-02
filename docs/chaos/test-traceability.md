# Test → chaos-experiment traceability

Two levels of the **same** proof. The in-process **functional tests** (`capstone-application-g03/services/*/src/test`)
are **level 1** — fast, deterministic, run on every CI build. The **Chaos Mesh experiments** (manifests under
`platform/chaos-mesh/`, reports `NN-name.md` in this directory) are **level 2** — the same hypothesis reproduced on the
real cluster under exactly one injected infrastructure failure. *"Resilience is a property you prove, not assume."*

**How to read a row.** If the level-1 test is green we *predict* the chaos run holds for the same reason. A **red** chaos
result with a **green** unit test localises the gap to the **environment** (wiring / infra / config), not the domain logic.
Experiment ids `01..08` are fixed by [`README.md`](README.md). Level-1 tests carry a JUnit `@Tag("chaos-NN")` where a
direct counterpart exists.

> Rewritten for the **async saga** (2026-07-02): the sync-era rows mapped breaker/bulkhead/relay tests
> (`PaymentsCircuitBreakerTest`, `BulkheadIsolationTest`, `OutboxPublisherTest`, …) that were retired with the cutover.

## Map

| # | Experiment | Level-1 functional test(s) | Shared hypothesis (level-1 proves ⇒ level-2 must hold) |
|---|---|---|---|
| **01** | `payments-latency` — slow consumer never reaches the user | `OrderTimeoutSweeperTest`, `OrderSagaTest` (guarded transitions), `PaymentsServiceTest` (idempotent authorize) | A slow Payments consumer just delays `payment-result`; orders park in `RESERVED`; the sweeper re-drives past PT2M and `UNIQUE(order_id)` makes the re-driven authorize a no-op → no double-charge, no stuck order, intake untouched (the ack never waits on Payments). |
| **02** | `inventory-podkill` — never-oversell under kill + redelivery | `InventoryConcurrencyTest` (last-seat race), `InventoryListenerIdempotencyTest` (redelivered command = no-op replay + reply re-emitted) | A pod killed mid-command is redelivered at-least-once (offset uncommitted); the atomic conditional `UPDATE` + `UNIQUE(order_id, trip_code)` converge to exactly one reservation outcome; the re-emitted `reservation-result` keeps Orders moving. |
| **03** | `node-disruption` — PDB + spread keep the money path up | `OrderVersionConcurrencyTest` (concurrent drivers → one terminal outcome), `OrdersIntakeRateLimiterTest` (429 shed under reduced capacity) | Survivors absorb the displaced load: concurrent terminal transitions emit exactly one `order-confirmed` (optimistic-lock losers roll back benignly); under pressure the intake sheds 429+Retry-After instead of collapsing. |
| **04** | `kafka-partition` — the saga freezes, converges on heal (CENTRAL) | `OrderSagaTest` (reply-driven guarded transitions), `OrderTimeoutSweeperTest` (re-drive), `InventoryListenerIdempotencyTest` + `PaymentCommandListenersTest` (idempotent consumers) | Unconsumed messages are delay, not loss (manual ack); on heal every guarded, idempotent transition applies exactly once; the sweeper re-drives whatever crossed the deadline; nothing lost, nothing duplicated. |
| **05** | `pg-failover` — RPO=0 **+ CDC resumes** | *(data part: pure infra — sync replication)*; CDC-gap self-healing maps to `OrderTimeoutSweeperTest` + the idempotent-consumer tests above | The failover surfaces as transient DB faults + a dead replication slot; the sweeper's re-drive generates fresh outbox rows on the new primary, closing the CDC gap for the money path. RPO/RTO themselves only the cluster can measure. |
| **06** | `connect-worker-kill` — CDC HA (3 workers) | *(pure infra — Connect group rebalance; no in-process counterpart)* consumers' dedup covers the at-least-once re-read | A worker death loses no position (slot LSN in PG, offsets in Kafka); at worst it re-reads unconfirmed WAL, which the idempotent consumers absorb. |
| **07** | `canary-auto-abort` — Rollouts aborts a bad release on the SLO gates | `OrdersIntakeRateLimiterTest` + `MetricCardinalityGuardTest` (the intake metrics the analysis queries exist and are well-formed); `OrdersControllerTest` (the ack path under test) | The analysis gates read the same `http_server_requests` + `spring_kafka_listener` series the tests pin; a degraded canary trips the p99 gate → the controller aborts with no human action. |
| **08** | `poison-message-dlt` — bounded retry → per-service DLT, no head-of-line blocking | `InventoryListenerIdempotencyTest` / `PaymentCommandListenersTest` (listener error path), the `KafkaErrorHandler` wiring (DefaultErrorHandler + FixedBackOff + DeadLetterPublishingRecoverer) asserted by context load | A message that keeps failing is retried 3×500 ms then dead-lettered and the offset committed — the partition moves on; the DLT carries the diagnostic headers. |

## Keeping this honest
When an experiment report (`01`..`08`) is written, link back to its row here. If a chaos run fails while its mapped
level-1 test is green, record in the report that the divergence is **environmental** (level-2 only) — that localisation is
the whole point of maintaining both levels. If a mapped test is renamed/retired in the app repo, update the row (this
file already survived one such rewrite: the sync→async cutover).
