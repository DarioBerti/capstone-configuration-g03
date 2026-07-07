# Checkout SLOs

SLOs for the **checkout money path** (create booking → add legs → pay → final state). They run live
as PrometheusRules (`observability.yaml`).

**Only sympthons that users can feel.** Everything else stays on a dashboard.

## The objectives

| # | Objective | Target | Window |
|---|---|---|---|
| SLO-1 | Intake success rate (sync request + response) | ≥ 99% | 28 days |
| SLO-2 | Intake response time (p99) | ≤ 300 ms | 28 days |
| SLO-3 | Saga reaches a final state (async) | ≥ 99% | rolling 30 min |
| SLO-4 | Orders stuck past deadline | = 0 | continuous |

Why four: the money path has two halves. The **intake** is synchronous (the HTTP calls the user waits
on) → it must be available (SLO-1) and fast (SLO-2). The **saga** is asynchronous — a fast `202` no
longer means "done" → we separately promise that every accepted booking **finishes** (SLO-3) and
nothing gets **stuck** (SLO-4).

Signals: SLO-1/2 come from the standard HTTP metrics on `orders`; SLO-3/4 from app counters
(confirmed/rejected vs placed) and the timeout-sweeper's stuck-orders gauge.

**Two things that are NOT failures:**
- **429**: the rate limiter shedding load on purpose is the system working; excluded from the SLI.
- **REJECTED**: a sold-out trip or declined card is a *correct* outcome. That's why SLO-3 counts
  "final state" (confirmed *or* rejected). The real failure is a booking that reaches neither —
  silently stuck — and only SLO-3/4 catch it.

## Alerts

| Alert | Fires when |
|---|---|
| Fast burn | error budget burning at ×14.4 (1h + 5m windows) |
| Slow burn | error budget burning at ×6 (6h + 30m windows) |
| Saga not completing | terminal ratio < 0.99 or stuck orders > 0 |
| Dead letters | DLT depth > 0: a message failed for good, won't self-heal |
| CDC stalled | Debezium down / replication slot lost — the outbox→Kafka pipe is broken |

Two burn windows because: the fast one catches a sudden break in minutes; the slow one catches a
gentle leak without paging. Each alert requires a long *and* a short window to agree.

## What does NOT page (dashboard only)

- **Consumer lag**: self-drains when the consumer catches up.
- **CPU / memory**: a cause, not user pain; busy CPU with a green success rate is fine. **We never page on CPU.**
- **429 rate**: intended backpressure
