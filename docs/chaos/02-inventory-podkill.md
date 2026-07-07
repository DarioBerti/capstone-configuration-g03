# Chaos 02 — Inventory pod-kill mid-reservation

**What:** kill one of the two Inventory replicas while a booking is reserving seats. Proves
never-oversell survives a real crash + at-least-once redelivery.

Run 2026-07-06 on AKS:
```bash
kubectl apply -f platform/chaos-mesh/02-inventory-podkill.yaml
```

## Results — ✅ PASS

- The booking placed during the kill reached **CONFIRMED**: the half-processed command was never acked
  (offsets commit only on a clean handler return), so Kafka redelivered it to the surviving replica.
- **Seat arithmetic exact: 75 → 74** — the redelivery was a harmless replay thanks to idempotent
  handlers + `UNIQUE(order_id, trip_code)`. No double-decrement, no lost decrement, never < 0.
- No outage (the survivor kept serving), no crash-loop; back to 2/2 on its own.

<<<<<<< HEAD
**Takeaway:** at-least-once + idempotency = exactly one reservation per order, even through a crash.
=======
>>>>>>> 582ea427d88224a1b23c3e8a8d7589c9f775502d
