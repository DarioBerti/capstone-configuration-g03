# Experiment 04 — Kafka disruption (THE central experiment)

**Maps to:** capstone chaos #4 · features: transactional outbox + **Debezium CDC** (log-based publication),
reply-driven saga, idempotent consumers, `OrderTimeoutSweeper`. Since the async cutover the **whole money
path lives on Kafka**, so this is no longer "one experiment among five" — it is the direct stress test of
the architecture's core claim: *a Kafka outage delays the saga, it never corrupts or loses it.*

- **Steady state (SLIs):** intake success-rate ≥ 99%; every order terminal within seconds; outbox tables
  drain to ~0 unpublished rows; consumer lag ~0.
- **Hypothesis:** cutting Orders off from Kafka freezes the saga's *progress* but not its *intake* and not
  its *correctness*:
  1. **Intake keeps accepting**: `POST /api/orders` still returns **202 durably** — `Order(PENDING)` + the
     `order-placed` outbox row commit in PostgreSQL, which is untouched. The 202 is an honest promise: the
     event is on disk, not in RAM.
  2. **The pipeline around Orders keeps moving**: Debezium (in the `kafka` ns, NOT partitioned) still
     publishes the outbox; Inventory/Payments still consume commands and publish replies. What stops is
     Orders *consuming* — new orders' sagas don't start (their `order-placed` waits), in-flight orders'
     replies queue up unconsumed.
  3. **On heal the system converges**: Orders drains the backlog (manual ack = nothing was lost by the
     partition), every order reaches **exactly one** terminal state. Orders parked past **PT2M** are
     re-driven by the sweeper; re-drives are idempotent downstream (`UNIQUE` dedup) → no duplicates.
- **Blast radius / one variable:** network partition Orders ↔ Kafka brokers only, ~3 min.
  *Broker-loss variant:* `PodChaos` on ONE broker — RF=3/minISR=2 must absorb it with **no visible effect**
  (run it as a warm-up: it should be a non-event, and that is the finding).
- **Method:** Chaos Mesh `NetworkChaos` (partition, both directions) between `app.kubernetes.io/name=orders`
  and `strimzi.io/cluster=eurotransit` (ns `kafka`) for 3 min under k6 load.
  Manifest: `platform/chaos-mesh/04-kafka-partition.yaml`.

## Observation (fill during the run)

```promql
# intake must stay green THROUGH the partition:
checkout_intake:error_ratio:rate5m
# orders' consumption stops, then catches up (rate -> 0 -> burst -> steady):
sum(rate(spring_kafka_listener_seconds_count{service="orders"}[1m]))
# broker-side: the orders group's lag balloons, then drains:
sum by (topic) (kafka_consumergroup_lag{consumergroup="orders"})
```

- During: intake 202s keep flowing (k6 error rate ~0); orders freeze in `PENDING`/`RESERVED`; DB check
  `SELECT COUNT(*) FROM outbox_events WHERE published_at IS NULL` should stay ~0 (Debezium is NOT cut) —
  the backlog is in the *unconsumed topics*, not in the outbox.
- After heal: every order placed before/during the partition reaches exactly one terminal state; sweeper
  re-drive lines only for orders that crossed PT2M; inventory: no oversell; payments: one authorization per
  order (`GROUP BY order_id HAVING COUNT(*) > 1` → 0 rows).

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Zero 5xx on the intake during the partition (a 429 shed under load is acceptable, it is not an error).
- [ ] All orders terminal after heal + sweeper window; nothing lost, nothing double-applied.
- [ ] Broker-loss variant: no measurable impact at all (RF=3/minISR=2 absorbed it).
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
