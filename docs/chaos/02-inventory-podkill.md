# Experiment 02 — Pod kill on Inventory mid-reservation

**Maps to:** capstone chaos #2 (the Pillar-B invariant) · in-process precursor: `InventoryConcurrencyTest`
(8-thread last-seat + concurrent-duplicate), `OrderVersionConcurrencyTest`.

- **Steady state (SLIs):** intake success-rate ≥ 99%; for a product with N seats, total reserved never exceeds N
  (the **never-oversell** invariant); no double-charge.
- **Hypothesis:** killing an Inventory pod **mid-reservation** does not break "never oversell" nor cause a
  double-charge: the atomic conditional `UPDATE ... WHERE available >= qty` commits or it doesn't, and the
  `UNIQUE(order_id, product_id)` dedup makes a redelivered `reserve` a no-op. At-least-once Kafka redelivery +
  idempotent handlers converge to exactly one reservation outcome per order.
- **Blast radius / one variable:** kill one Inventory pod while reservations are in flight.
- **Method:** Chaos Mesh `PodChaos` (pod-kill) on `app=inventory` during a burst of concurrent orders for the
  **same scarce product** (e.g. the 1-seat demo SKU). Manifest: `platform/chaos-mesh/02-inventory-podkill.yaml`.

## Observation
<verify via GET /api/inventory/items/{id}: available never < 0; count reservations RESERVED+CONFIRMED ≤ seats;
payments authorizations = one per order — screenshots/links>

## Conclusion
- Hypothesis held? <yes/no>  (oversell? double-charge? — expected: NO to both)
- What we changed if it didn't: <...>
