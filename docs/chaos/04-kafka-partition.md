# Chaos 04 — Kafka partition (the central one)

**What:** network-partition Orders from the Kafka brokers for ~3 minutes. Since the async cutover the
whole money path lives on Kafka, so this is the architecture's core claim: a Kafka outage delays the
saga, it never loses or corrupts anything.

Run 2026-07-06 on AKS:
```bash
kubectl apply -f platform/chaos-mesh/04-kafka-partition.yaml
```

## Results — ✅ PASS

- **During:** the intake kept accepting durably (create/add-leg → 201) — the 201/202 is an honest
  promise because the order + outbox row are committed in Postgres, untouched by the partition. The
  saga **froze** (leg PENDING, order HELD): Orders couldn't consume its replies, which just waited in
  their topic. Nothing lost, nothing corrupted, no 5xx.
- **After heal:** Orders drained the backlog — leg **RESERVED within 3s**, then pay → **CONFIRMED**.
  The saga converged.
- An order stuck past the 2-minute deadline would be re-driven idempotently by the timeout sweeper.

**Takeaway:** a Kafka outage is a *delay*, never a loss — progress stops, correctness doesn't.
