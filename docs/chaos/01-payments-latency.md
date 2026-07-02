# Experiment 01 — Latency injection into Payments (slow consumer)

**Maps to:** capstone chaos #1 · Pillar C in async form: **temporal decoupling** (Kafka buffers the failure
as consumer lag), bounded consumer retry + DLT, `OrderTimeoutSweeper` liveness backstop, `@RateLimiter`
edge backpressure. The sync-era version of this experiment proved a circuit breaker OPENing; the breaker was
retired with the async cutover (see `docs/design.md §4-C`) — **this run proves its replacement does the same
job better**: the user never sees the downstream failure at all.

- **Steady state (SLIs):** checkout intake success-rate ≥ 99% and ack p99 ≤ 300 ms (`docs/design.md §4-D`);
  orders reach a terminal state within seconds; consumer lag ~0 on all saga topics; all three DLTs empty.
- **Hypothesis:** injecting ~3 s of network latency between Payments and Kafka slows its consumption of
  `authorize-payment` / `capture-payment` and the publication of its replies. Effects, in order:
  1. **The intake does not notice.** `POST /api/orders` keeps returning 202 within the ack SLO — the slow
     step is behind Kafka, not on the request thread. The failure surfaces as **consumer lag + orders parked
     in `RESERVED`**, not as user-facing errors. (This is the async answer to "contain, don't propagate".)
  2. **No order is lost or stuck forever.** Orders parked past the sweeper deadline (**PT2M**) get their
     current-state command re-emitted; commands are idempotent downstream (`UNIQUE(order_id)` in payments)
     so a re-drive can never double-charge.
  3. **Catalog browsing is untouched** (different service, different DB, no shared sync path).
- **Blast radius / one variable:** network delay on the Payments↔Kafka path only. Payments' DB and the other
  services are untouched.
- **Method:** Chaos Mesh `NetworkChaos` (delay 3 s ± 200 ms) between `app.kubernetes.io/name=payments` and
  the Kafka brokers for **5 min**, under steady k6 load (`just loadtest`).
  Manifest: `platform/chaos-mesh/01-payments-latency.yaml`.

## Observation (fill during the run)

PromQL to watch (Grafana explore or the RED dashboards):

```promql
# intake stays healthy (should NOT move):
checkout_intake:error_ratio:rate5m
histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{uri="/api/orders", method="POST"}[5m])))
# the failure shows up HERE instead (should grow, then drain):
sum by (topic) (kafka_consumergroup_lag{group="payments"})             # broker-side lag view
sum(rate(spring_kafka_listener_seconds_count{service="payments"}[2m])) # payments consumption rate
```

- During injection: `RESERVED` count grows (orders awaiting `payment-result`); intake SLIs flat; lag on
  `authorize-payment` grows.
- After heal: lag drains; parked orders progress to `CONFIRMED`/`REJECTED`; sweeper log lines
  (`re-driving N stuck order(s)`) only for orders that crossed PT2M.
- Payments DB: `SELECT order_id, COUNT(*) FROM payment_authorizations GROUP BY order_id HAVING COUNT(*) > 1;`
  → **must return 0 rows** (no double-charge, even where the sweeper re-drove).

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Intake success-rate and ack p99 stayed within SLO for the whole injection (no user-visible failure).
- [ ] Zero non-terminal orders 5 min after heal (sweeper + idempotent re-drive worked).
- [ ] Zero duplicate authorizations; DLTs still empty (latency is not an error — nothing poisoned).
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
