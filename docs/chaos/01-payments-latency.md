# Chaos 01 — Latency into Payments

**What:** inject 3s of network delay (both directions) between Payments and the Kafka brokers for 5
minutes. Nothing else is touched. Proves a slow downstream never reaches the user — the slow step is
behind Kafka, not on the request thread.

Run 2026-07-06 on AKS:
```bash
kubectl apply -f platform/chaos-mesh/01-payments-latency.yaml
```

## Results — ✅ PASS

- Intake unaffected: create 0.22s, pay ack 0.15s (202 returns immediately), browse 0.21s.
- The order still reached **CONFIRMED — in 21s instead of ~5s**. The fault surfaced as saga slowness,
  never as a user-visible error or a lost order.
- No DLT entries (latency is not an error). If an order crossed the 2-minute deadline, the timeout
  sweeper would re-drive it idempotently (no double-charge).

<<<<<<< HEAD
**Takeaway:** temporal decoupling contains the failure — the async replacement for the circuit breaker,
and the user sees nothing.
=======
## Verdict
✅ **PASS.** Intake ack + catalog stayed fast (well within the 300 ms SLO) throughout; the order confirmed
(slower but correct); no lost order, no double-charge, no DLT (latency is not an error → nothing poisoned).
Hypothesis held; nothing changed.


>>>>>>> 582ea427d88224a1b23c3e8a8d7589c9f775502d
