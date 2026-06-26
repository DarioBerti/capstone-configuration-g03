# Test → chaos-experiment traceability (Fase 2 #5.6)

Two levels of the **same** proof. The in-process **functional tests** (`capstone-application-g03/services/*/src/test`)
are **level 1** — fast, deterministic, run on every CI build. The **Chaos Mesh experiments** (manifests *planned* under
`platform/chaos-mesh/`, reports `NN-name.md` in this directory) are **level 2** — the same hypothesis reproduced on the
real cluster under exactly one injected infrastructure failure. *"Resilience is a property you prove, not assume"*
(deck 11, slide 41).

**How to read a row.** If the level-1 test is green we *predict* the chaos run holds for the same reason. A **red** chaos
result with a **green** unit test localises the gap to the **environment** (wiring / infra / config), not the domain logic.
Experiment ids `01..05` are fixed by [`README.md`](README.md); this doc invents none. Each level-1 test also carries a
JUnit `@Tag("chaos-NN")` so CI can later select a per-experiment suite (`--tests`/tag filter) once the manifests exist.

## Map

| # | Experiment (planned manifest) | Level-1 functional test(s) — `@Tag` | Shared hypothesis (level-1 proves ⇒ level-2 must hold) |
|---|---|---|---|
| **01** | `payments-latency` — breaker opens, fallback engages, Catalog healthy | `PaymentsCircuitBreakerTest`, `PaymentsGatewayBreakerIntegrationTest`, `PaymentsRetryTest`, `PaymentsRetryIntegrationTest`, `BulkheadIsolationTest`, `OrderRecoverySweeperTest`, `OrderSagaTest` (parking methods) — `@Tag("chaos-01")` | Sustained Payments latency makes >50% of the window **slow** → the breaker **OPENs** and fast-fails (`CallNotPermittedException`); a **short blip** is absorbed by bounded retry+jitter and never trips it; the fallback **parks** the order (`PAYMENT_PENDING`) instead of propagating, seats stay held, and the recovery sweep confirms once Payments heals. The per-downstream **bulkhead** stops the latency starving Inventory, so Catalog browsing stays healthy. |
| **02** | `inventory-podkill` — no oversell / no double-charge mid-reservation | `InventoryConcurrencyTest`, `PaymentsServiceTest`, `PaymentsRetryIdempotencyIntegrationTest`, `OrderSagaTest` (compensation methods) — `@Tag("chaos-02")` | A pod killed mid-reservation triggers Kafka **at-least-once redelivery** and concurrent drivers. Atomic conditional `UPDATE` + `UNIQUE(order_id[,product_id])` + `@Version` make a redelivered reserve/authorize/void an **idempotent replay**: never oversell, never a second charge (proven build-breaking by `PaymentsRetryIdempotencyIntegrationTest`: a charge that commits then loses its response is retransmitted and still charges once). If a hold lapses post-authorize the saga **VOIDs before rejecting** ("no charge without a seat"). |
| **03** | `node-disruption` — PDBs + topology spread keep the critical path available | `OrderVersionConcurrencyTest`, `OrdersIntakeRateLimiterTest` — `@Tag("chaos-03")` | Losing a node leaves multiple replicas + the sweeper running on survivors. Concurrent **terminal** transitions emit exactly **one** `order-confirmed` + one `notification-requested` (optimistic-lock losers roll back). Under reduced capacity the intake **sheds** `429 + Retry-After` (controlled refusal) instead of collapsing, keeping survivors responsive. |
| **04** | `kafka-partition` — pipeline converges after heal; nothing lost/duplicated | `OutboxPublisherTest` (+ the idempotent consumers above) — `@Tag("chaos-04")` | A broker partition stops delivery; on heal the **transactional outbox** re-drains in creation order and marks each event once, and every consumer is idempotent, so the async pipeline converges with **nothing lost and nothing duplicated**. |
| **05** | `pg-failover` — checkout impact + recovery within RTO | *(no direct in-process counterpart — pure infra)* nearest analogs: `OrderSagaTest` parking + `OrderRecoverySweeperTest` (`chaos-01`) | A primary failover surfaces to the app as **transient transport faults** on in-flight DB work; those map to the breaker/park path proven at level 1, so checkout degrades to `PAYMENT_PENDING` and the recovery sweep drains once the new primary is up. The RTO itself (`slo.md`, recover-to-SLO target) is an infra property only the cluster experiment can measure. |

## Not anticipating a chaos experiment (intentionally)
- `RetryBulkheadConfigTest`, `OrdersApplicationTests`, and `PaymentsCircuitBreakerTest`'s **config-assertion** method **pin
  `application.yml` bindings** (non-default thresholds). They guard that the policies are *wired*, not that they survive a
  failure — there is no infra fault to inject, so they carry no `@Tag`.
- `PaymentsGateway4xxTest` exercises a **business/contract** outcome (4xx → terminal `DECLINED`, breaker **not** tripped),
  not an injected infra failure. It is a **control** for experiment 01: it proves a business decline is not mistaken for the
  latency fault the breaker watches.

## Keeping this honest
When an experiment report (`01`..`05`) is written, link back to its row here. If a chaos run fails while its mapped
level-1 test is green, record in the report that the divergence is **environmental** (level-2 only) — that localisation is
the whole point of maintaining both levels.
