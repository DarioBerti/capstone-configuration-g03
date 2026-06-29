# Experiment 04 — Network partition / Kafka disruption

**Maps to:** capstone chaos #4 · features: transactional outbox (at-least-once) + idempotent consumers +
manual-ack consumption.

- **Steady state (SLIs):** intake success-rate ≥ 99%; outbox drains to empty; Kafka consumer lag ~0.
- **Hypothesis:** partitioning Orders from Kafka does **not** lose or duplicate the money path: `POST /api/orders`
  still returns 202 (order + outbox row commit locally), the outbox relay **retries** publishing once the
  partition heals (at-least-once), and idempotent consumers (`UNIQUE` dedup) absorb any redelivery — so after
  the heal the system **converges** with nothing lost and nothing double-applied.
- **Blast radius / one variable:** partition Orders ↔ Kafka (or kill a broker) for ~3 min, then heal.
- **Method:** Chaos Mesh `NetworkChaos` (partition) between `app=orders` and the Kafka brokers (or `PodChaos`
  on one broker — RF=3/minISR=2 should tolerate one). Manifest: `platform/chaos-mesh/04-kafka-partition.yaml`.

## Observation
<during partition: outbox `published_at IS NULL` backlog grows, intake still 202; after heal: backlog drains,
consumer lag returns to ~0; assert each order reaches exactly one terminal state — screenshots/links>

## Conclusion
- Hypothesis held? <yes/no>  (anything lost or duplicated? — expected: NO)
- What we changed if it didn't: <...>
