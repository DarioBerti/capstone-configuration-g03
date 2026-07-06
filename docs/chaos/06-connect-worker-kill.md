# Chaos 06 — Kafka Connect worker kill (Debezium CDC self-heals)

**Proves (Pillar A/C):** since the async cutover, **Debezium is the only path from a committed outbox row to
Kafka** — a stopped CDC would accept orders but never progress them. This proves the 2-replica Connect cluster
makes a worker death a self-healing non-event with **zero loss**.

**Run:** 2026-07-06, live on AKS, Chaos Mesh `PodChaos`. *Config adjustment: Connect runs **2** workers → kill
**one** (`mode: one`), the surviving worker keeps the connector tasks running.*

## Steady state (before)
- Connect workers: **2/2 Running** (`connect-0`, `connect-1`)
- Connectors: `orders-outbox`, `inventory-outbox`, `payments-outbox` all **READY=True (RUNNING)**

## The one fault injected
```bash
kubectl apply -f platform/chaos-mesh/06-connect-worker-kill.yaml   # PodChaos pod-kill, mode: one, debezium-connect
```
It killed `debezium-connect-connect-1`; the pod was immediately recreated.

## What we observed
- **The surviving worker `connect-0` kept the connectors RUNNING** — all three connectors stayed `READY=True`
  throughout (Connect's group protocol keeps the tasks on the live member; no task went permanently FAILED).
- **CDC gap was tiny.** A booking placed right after the kill got its `reserve-seats` published and its leg
  **RESERVED in 4 s**, then reached **CONFIRMED in 16 s** total — the outbox→Kafka path barely paused.
- **Intake durable throughout** (add-leg 201, pay 202): the money path keeps accepting because a 202 means the
  row is committed in Postgres; the outbox backlog (if any) drains once CDC catches up.
- **Zero loss by construction:** the replication slot's confirmed LSN lives server-side in PostgreSQL and the
  connector offsets live in Kafka, so a worker death can only re-read unconfirmed WAL (at-least-once → idempotent
  consumers dedup). The killed worker recovered to rejoin the cluster.

## Verdict
✅ **PASS.** Task stayed/rebalanced onto the surviving worker with no human action, publication gap of seconds,
the order confirmed, intake unaffected, zero lost events. Hypothesis held; nothing changed.

## For the oral (one breath)
> "Debezium is now the only bridge from the outbox to Kafka, so we kill a Connect worker. The other worker keeps
> the connectors running, the CDC pauses for a few seconds at most, and the order confirms. Nothing is lost —
> the slot's confirmed position lives in Postgres and the offsets live in Kafka, so a dead worker just re-reads
> a little unconfirmed WAL, which idempotent consumers dedup."
