# Chaos 04 — Kafka partition (THE central one: a Kafka outage delays, never corrupts)

**Proves (Pillar A, the architecture's core claim):** since the async cutover the **whole money path lives on
Kafka**. Cutting Orders off from Kafka must **freeze the saga's progress but not its intake and not its
correctness** — a delay, never a loss or a corruption.

**Run:** 2026-07-06, live on AKS, Chaos Mesh `NetworkChaos` (partition). *Config adjustment: none (a network
partition Orders↔Kafka; independent of the broker co-location).*

## Steady state (before)
- Intake success-rate ≥ 99%; orders terminal in ~5 s; outbox drains to ~0 unpublished; consumer lag ~0.

## The one fault injected
```bash
kubectl apply -f platform/chaos-mesh/04-kafka-partition.yaml   # NetworkChaos partition, both directions,
                                                               # orders ↔ Kafka brokers only, ~3m (auto-reverts)
```

## What we observed
**During the partition** (Orders isolated from Kafka):
- `POST /api/orders` → **201**, `POST /{id}/legs` → **201** — the **intake keeps accepting durably**. A 201/202
  is an honest promise: the `Order` + `OrderLeg` + `reserve-seats` outbox row are committed in **Postgres**,
  which is untouched by the partition.
- The order **froze**: leg **PENDING**, order **HELD** for the full ~24 s window — Orders cannot *consume* the
  `reservation-result` reply while cut off from Kafka, so the saga's **progress stops**. Nothing is corrupted or
  lost; the reply just waits in its topic. *(Debezium is in the `kafka` namespace and is NOT partitioned, so the
  outbox still publishes; what stops is Orders consuming.)*

**After heal** (partition removed):
- Orders reconnected and **drained the backlog**: the leg went **RESERVED within 3 s** (the queued reply was
  consumed — nothing was lost during the outage), then `pay` → **CONFIRMED**. The saga **converged**.

An order parked past the 2-minute deadline would instead be re-driven by `OrderTimeoutSweeper` (idempotent —
`UNIQUE(order_id)`/`UNIQUE(order_id, trip_code)` → no double-charge, no oversell). *Documented warm-up variant
(not re-run here): `PodChaos` on ONE broker — RF=3 / `min.insync.replicas=2` absorbs it with no visible effect.*

## Verdict
✅ **PASS.** Intake stayed durable through the partition (no 5xx), the saga froze but never corrupted, and on
heal every order converged to exactly one terminal state with nothing lost or double-applied. Hypothesis held;
nothing changed.

