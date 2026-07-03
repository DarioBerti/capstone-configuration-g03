# Experiment 02 — Pod kill on Inventory mid-reservation

**Maps to:** capstone chaos #2 (the Pillar-B invariant) · in-process precursor: `InventoryConcurrencyTest`
(8-thread last-seat + concurrent-duplicate), `InventoryListenerIdempotencyTest`, `OrderVersionConcurrencyTest`.

- **Steady state (SLIs):** intake success-rate ≥ 99%; for a trip with N seats, total reserved never exceeds N
  (the **never-oversell** invariant); no double-charge; consumer lag ~0.
- **Hypothesis:** killing an Inventory pod **mid-command** does not break "never oversell" nor lose an order.
  The async mechanics that make this safe:
  1. offsets are committed only on a clean handler return (`enable-auto-commit=false`) → a pod killed
     mid-`reserve-seats` never acked it, so Kafka **redelivers** the command to a surviving pod (rebalance);
  2. the atomic conditional `UPDATE ... WHERE available >= qty` either committed before the kill or it
     didn't — there is no half-reservation; the `UNIQUE(order_id, trip_code)` dedup makes the redelivered
     command a **no-op replay** if it had committed (and the handler re-emits the `reservation-result`
     reply, so Orders is never left waiting);
  3. at-least-once + idempotent handlers therefore converge to **exactly one reservation outcome per order**.
- **Blast radius / one variable:** kill one Inventory pod while commands are in flight (the second replica
  and the group rebalance absorb it).
- **Method:** Chaos Mesh `PodChaos` (pod-kill) on `app.kubernetes.io/name=inventory` during a burst of
  concurrent orders for the **same scarce trip** (e.g. a 1-seat demo trip).
  Manifest: `platform/chaos-mesh/02-inventory-podkill.yaml`.

## Observation (fill during the run)

- `GET /api/inventory/items/{tripCode}`: `available` never < 0; reservations `RESERVED+CONFIRMED ≤ seats`.
- Rebalance visible in the surviving pod's log (`partitions assigned`); redelivered commands logged as
  idempotent no-ops, each still answered with a `reservation-result` reply.
- Payments: one authorization per order (`GROUP BY order_id HAVING COUNT(*) > 1` → 0 rows).
- Every order placed during the kill reaches exactly one terminal state (sweeper covers any lost reply).

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Never-oversell held (seat arithmetic exact under kill + redelivery).
- [ ] No double-charge; no order left non-terminal after the sweeper window (PT2M).
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
