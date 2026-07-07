# Agent verification log

> Capstone rule: AI agents are allowed, but the team must verify their output and show where the agent was wrong.
> Each entry: **error → fix**.

## 1. "HA" databases used async replication

- **Error:** the agent marked the money-path databases "HA" with 2 instances, but left CloudNativePG's default async replication: a failover could lose committed reservations (seat sold twice).
- **Fix:** synchronous replication on `inventory-db`; `preferred` synchronous on `orders-db`.

## 2. JPA quirk dropped a state change → double restock

- **Error:** in `release()`, a bulk update with `clearAutomatically = true` wiped the pending `RELEASED` status before it was saved; a second call restocked the seats twice.
- **Fix:** flush the status change before the bulk update (`flushAutomatically = true` + explicit `save()`).

## 3. Restock path had no concurrency guard

- **Error:** reserve was atomic, but confirm/release/expire did read-then-write with no locking; with 2 replicas, two threads could both restock the same hold → oversell.
- **Fix:** optimistic locking (`@Version`) on `Reservation`; the race loser rolls back before restocking. Proven with a concurrency test.

## 4. Circuit-breaker fallback hid permanent faults

- **Error:** every Payments error was treated as "retry later": a 4xx was retried forever, a long outage could re-charge an order with an expired hold, and one bad order aborted the whole recovery sweep.
- **Fix:** 4xx → terminal `DECLINED`; never charge against an expired hold; per-order error isolation in the sweep; concurrency test added.

## 5. Refund design only counted the money leak

- **Error:** when voiding a charge failed, the design just incremented a counter and rejected the order: during a Payments outage the charge was never actually reversed.
- **Fix:** a failed void is parked and retried until it succeeds; expiry attempts the void first.

## 6. Kafka contract built by three agents with no shared schema

- **Error (risk):** producer and consumer of each topic were written by different agents; a typo in a topic name or status literal would pass all tests and fail silently at runtime.
- **Fix:** contract (topics, fields, status spellings) pinned in every agent's brief before fan-out, then verified against the source and `kafka-topics.yaml` after. No drift.

## 7. Tracing dependencies were inert

- **Error:** the agent assumed deps + properties were enough, but Spring Boot 4 moved tracing auto-configuration to a separate module: zero spans, no error anywhere.
- **Fix:** add `spring-boot-micrometer-tracing-opentelemetry` to all six services; verified via the persisted `traceparent`.
