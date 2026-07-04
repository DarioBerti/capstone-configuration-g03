# Experiment 05 — CloudNativePG primary failover (RPO=0 **+ the CDC must resume**)

**Maps to:** capstone chaos #5 · features: synchronous replication (inventory-db `required`, orders-db
`preferred`) → **RPO = 0**, and — new with the async cutover — the **Debezium replication slot** riding the
failover. The experiment now has TWO invariants to prove, and the second is the delicate one.

- **Steady state (SLIs):** intake success-rate ≥ 99%; inventory-db 1 primary + 2 sync standbys Ready;
  never-oversell holds; Debezium connectors `RUNNING`, outbox rows published within ~1 s.
- **Hypothesis (part 1 — data, unchanged):** killing the inventory-db **primary** costs a brief write stall
  while CNPG promotes a standby, but **no committed reservation is lost** (`dataDurability: required` → the
  commit had already reached a sync standby). Never-oversell holds; recovery within **RTO ≤ 60 s**.
- **Hypothesis (part 2 — CDC, the new part):** the failover **breaks the Debezium slot** — a PG16 logical
  slot lives only on the primary (annotated in `templates/databases.yaml`). Expected sequence:
  1. the connector task fails (`connection to server lost`), Kafka Connect retries and reconnects via the
     `-rw` Service (which CNPG re-points to the new primary), and **recreates the slot** there;
  2. outbox rows committed **in the gap** (between promotion and slot recreation) are never decoded from
     the WAL (`snapshot.mode: no_data`) — **but the money path self-heals anyway**: the sweeper re-drives
     any order stuck past PT2M (→ a *fresh* outbox row, captured by the new slot) and the idempotent
     handlers re-emit their replies. What can be lost **permanently** is only a terminal/notification event
     in the gap (notifications are best-effort by design — documented degradation, not an invariant breach);
  3. publication resumes and the backlog drains.
- **Blast radius / one variable:** kill the primary pod of `inventory-db` only (repeat later on `orders-db`).
- **Method:** Chaos Mesh `PodChaos` pod-kill selecting `cnpg.io/cluster=inventory-db, role=primary`, under
  steady reservation load. Manifest: `platform/chaos-mesh/05-pg-failover.yaml`.

## Target posture — DECIDED 2026-07-03: stay on PG16 (no failover slots)

The prod-grade fix for part 2 is **PostgreSQL 17 failover slots** (`sync_replication_slots=on` + the slot
created with `failover=true`): the slot is synchronized to the standbys, so after promotion Debezium resumes
**with zero gap** — no missed events at all, not even notifications. Requires the declarative PG16→17 major
upgrade (CNPG ≥1.26 supports it; we run 1.29.1) + the connector's slot config; publication (Flyway) is
version-agnostic. **When that lands, re-run this experiment: part 2's PASS bar rises from "self-heals with
documented notification loss" to "zero missed events".**

## Observation (fill during the run)

```bash
kubectl cnpg status inventory-db -n eurotransit          # before/during/after: promotion timeline
kubectl -n kafka get kafkaconnector -o wide              # connector state: RUNNING -> FAILED/RESTARTING -> RUNNING
kubectl -n eurotransit exec deploy/orders -- sh -c '...' # or psql: pg_replication_slots on the NEW primary
```
```promql
checkout_intake:error_ratio:rate5m                       # the dip + recovery vs the 60 s RTO
sum(rate(spring_kafka_listener_seconds_count{service="inventory"}[1m]))  # command consumption resumes
```

- Data: available seats after failover == committed state before (no lost reservation → RPO=0); no oversell.
- CDC: timestamp when the connector failed, when the slot reappeared on the new primary, when the first
  post-failover outbox row hit Kafka → the **CDC gap window**. List any order whose event fell in the gap
  and verify the sweeper re-drove it to terminal.

<screenshots/links>

## Conclusion — PASS criteria
- [ ] RPO = 0 (no committed reservation lost) and intake recovery ≤ 60 s.
- [ ] Never-oversell held through the failover.
- [ ] CDC resumed **without human action**; every money-path order reached exactly one terminal state
      (sweeper covered the gap); any permanently-lost event was ONLY a best-effort notification (log it).
- [ ] *(after the PG17 failover-slot upgrade)* zero missed events — the gap window is 0.
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
