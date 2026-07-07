# Chaos 02 — Pod-kill on Inventory mid-reservation (never-oversell survives)

**Proves (Pillar B):** killing an Inventory pod while it is reserving seats cannot oversell and cannot lose an
order. This is the never-oversell invariant under a real crash + at-least-once redelivery.

**Run:** 2026-07-06, live on AKS, Chaos Mesh `PodChaos`. *Config adjustment: inventory runs **2** replicas → kill
**one** (`mode: one`) so the surviving replica keeps serving — we test convergence, not an outage.*

> **Chaos-session prerequisite (this cluster):** Chaos Mesh's control plane is scaled to **0** by default to save
> memory on the tight student pool. Scale it up first: `kubectl -n chaos-mesh scale deploy chaos-controller-manager
> --replicas=1` (wait ~30s for the webhook cert), then scale back to 0 when done.

## Steady state (before)
- FR9612 `available`: **75** · inventory: **2/2 Running**

## The one fault injected
```bash
kubectl apply -f platform/chaos-mesh/02-inventory-podkill.yaml   # PodChaos pod-kill, mode: one, selector inventory
```
It killed replica `inventory-…-gnkgd` (confirmed in the PodChaos record) while a booking was in flight.

## What we observed
- The Deployment **immediately created a replacement** pod; the **surviving replica `…zrj9c` kept serving**
  throughout — no outage.
- The booking placed **during the kill** reached **CONFIRMED** (leg → RESERVED → pay → CONFIRMED). The order was
  **not lost**: offsets commit only on a clean handler return (`enable-auto-commit=false`), so a command killed
  mid-`reserve-seats` was never acked and Kafka **redelivered** it to the survivor; idempotent handlers +
  `UNIQUE(order_id, trip_code)` make a redelivery a harmless replay.
- **Seat arithmetic exact:** `available` **75 → 74** (−1 for one CONFIRMED qty 1). Never < 0 → **never-oversell
  held**; no double-decrement, no lost decrement.
- **No crash-loop**; inventory recovered to 2/2.

## Verdict
✅ **PASS.** Never-oversell held with exact seat arithmetic, the order confirmed straight through the kill, no
double-charge, and Inventory self-recovered. Hypothesis held; nothing changed.

