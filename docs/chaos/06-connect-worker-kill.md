# Experiment 06 — Kafka Connect worker kill (Debezium CDC HA)

**Maps to:** the async cutover's new critical dependency — **Debezium is now the only path from a committed
outbox row to Kafka**. A stopped CDC = a money path that accepts orders but never progresses them. This
experiment proves the 3-replica Kafka Connect cluster makes that a self-healing non-event.

- **Steady state (SLIs):** the 3 Connect workers Ready (`strimzi.io/cluster=debezium-connect`, ns `kafka`);
  all three connectors + tasks `RUNNING`; outbox rows published within ~1 s (end-to-end order latency ~s).
- **Hypothesis:** killing the worker that runs a connector task pauses that connector's publication for a
  few seconds only: Connect's group protocol detects the dead member and **rebalances the task onto a
  surviving worker**, which resumes **exactly where the slot left off** — the replication slot's confirmed
  LSN lives server-side in PostgreSQL and the connector offsets live in Kafka itself, so a worker death can
  lose **nothing**: at worst it re-reads unconfirmed WAL (at-least-once; consumers dedup). Meanwhile the
  intake keeps accepting durably (202 = row in PG) and a short outbox backlog accumulates, then drains.
- **Blast radius / one variable:** one Connect worker pod (of 3), killed while a connector task runs on it.
- **Method:** find the worker hosting the `orders-outbox` task
  (`kubectl -n kafka get kafkaconnector orders-outbox -o yaml | grep worker_id` or the Connect REST
  `/connectors/orders-outbox/status`), then Chaos Mesh `PodChaos` pod-kill on that pod, under k6 load.
  Manifest: `platform/chaos-mesh/06-connect-worker-kill.yaml`.

## Observation (fill during the run)

```bash
kubectl -n kafka get pods -l strimzi.io/cluster=debezium-connect -w    # kill -> reschedule
kubectl -n kafka get kafkaconnector -o wide                            # task FAILED/UNASSIGNED -> RUNNING (new worker)
```
```promql
# publication gap = flat spot in orders' consumption, then a catch-up burst:
sum(rate(spring_kafka_listener_seconds_count{service="orders"}[1m]))
```
- Timestamp the kill → task reassigned → first post-kill outbox row on Kafka = **the CDC gap** (expect
  seconds, not minutes).
- After: outbox `published_at IS NULL` ~0 (if tracked) / end-to-end order latency back to steady; every
  order placed during the gap reaches exactly one terminal state; no duplicate side-effects downstream
  (redelivered events are deduped).

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Task rebalance without human action; publication gap ≤ ~60 s.
- [ ] Zero lost events (slot LSN server-side) and zero duplicate side-effects (idempotent consumers).
- [ ] Intake unaffected throughout (202s durably accepted).
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
