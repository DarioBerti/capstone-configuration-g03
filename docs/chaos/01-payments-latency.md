# Experiment 01 — Latency injection into Payments

**Maps to:** capstone chaos #1 · resilience features Fase 2 #1/#2 (circuit breaker + retry + bulkhead) ·
in-process precursor: `PaymentsCircuitBreakerTest` / `PaymentsGatewayBreakerIntegrationTest`.

- **Steady state (SLIs):** checkout intake success-rate ≥ 99% and ack p99 ≤ 300 ms (SLO 1/2 in `slo.md`);
  Catalog read latency nominal; breaker `payments` CLOSED.
- **Hypothesis:** injecting high latency into Payments makes the Orders→Payments circuit breaker **OPEN**;
  authorize then **fast-fails** to the `UNAVAILABLE` fallback → orders park in `PAYMENT_PENDING` (not rejected,
  not hung), and **Catalog browsing stays healthy** (bulkhead isolates the Payments pool). The intake ack
  latency SLO is **not** breached (the saga is async; the slow call is off the request thread).
- **Blast radius / one variable:** add ~3 s latency to Payments pod(s) only.
- **Method:** Chaos Mesh `NetworkChaos` (delay) on `app=payments` for ~5 min, under steady load (k6) on
  `POST /api/orders` and `GET /api/catalog/products`. Manifest: `platform/chaos-mesh/01-payments-latency.yaml`.

## Observation
<dashboards/traces: breaker state series `resilience4j_circuitbreaker_state{name="payments"}`, `orders_payment_failures_total{outcome="unavailable"}`, `orders_recovery_total`, Catalog RED panel — screenshots/links>

## Conclusion
- Hypothesis held? <yes/no>
- Recovery: after latency removed, breaker HALF_OPEN→CLOSED, recovery sweep drains PAYMENT_PENDING → CONFIRMED.
- What we changed if it didn't: <...>
