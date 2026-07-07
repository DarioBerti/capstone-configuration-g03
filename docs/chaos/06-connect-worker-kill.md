# Chaos 06 — Kafka Connect worker kill

**What:** kill one of the two Debezium/Connect workers. Debezium is the *only* path from a committed
outbox row to Kafka, so a dead CDC would accept orders but never progress them — this proves the
2-worker cluster makes it a self-healing non-event.

Run 2026-07-06 on AKS:
```bash
kubectl apply -f platform/chaos-mesh/06-connect-worker-kill.yaml
```

## Results — ✅ PASS

- **The surviving worker kept all three connectors RUNNING** throughout; the killed pod was recreated
  and rejoined.
- **CDC gap of seconds:** a booking placed right after the kill got its leg RESERVED in 4s and
  **CONFIRMED in 16s**. Intake stayed durable the whole time.
- **Zero loss by construction:** the replication slot's confirmed position lives in Postgres and the
  connector offsets live in Kafka — a dead worker can only re-read a little unconfirmed WAL, which
  idempotent consumers dedup.

**Takeaway:** the one bridge between outbox and Kafka is HA; a worker death costs seconds, not orders.
