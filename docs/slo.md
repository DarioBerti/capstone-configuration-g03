# Checkout SLOs — EuroTransit (g03)

The service-level objectives for the **checkout money path** — the one flow a customer actually cares about:
create a booking, add legs, pay, and reach a final state (CONFIRMED, or a legitimate REJECTED) quickly and
reliably.

These objectives are **live**, not just written here: they are the `eurotransit-checkout-slo` and
`eurotransit-saga-slo` PrometheusRules (from `deploy/charts/eurotransit/templates/observability.yaml`),
evaluated by kube-prometheus on the cluster.

**One rule guides all alerting: page only when a human is needed *and* users are hurting right now.**
Everything else is a dashboard signal, not a 3 a.m. phone call.

---

## 1. The objectives (what we promise)

| # | Objective | Target | Window |
|---|---|---|---|
| SLO-1 | Intake success rate | **≥ 99%** | 28 days |
| SLO-2 | Intake response time (p99) | **≤ 300 ms** | 28 days |
| SLO-3 | Saga reaches a final state | **≥ 99%** | rolling 30 min |
| SLO-4 | Orders stuck (non-final past deadline) | **= 0** | continuous |

**Why these four.** The money path has two halves, so it needs two kinds of promise:

- The **intake** is synchronous — the HTTP calls the user waits on (`POST /api/orders`, `.../legs`, `.../pay`).
  It must be **available** (SLO-1) and **fast** (SLO-2).
- The **saga** is asynchronous — after the `202`, Orders drives Inventory and Payments over Kafka. A fast `202`
  no longer means "done", so we separately promise that every accepted booking actually **finishes** (SLO-3) and
  that **nothing gets stuck** (SLO-4).

---

## 2. The signals (SLIs — what we measure)

| SLI | How it's computed | Metric source |
|---|---|---|
| Intake success rate | non-5xx responses ÷ all responses on the intake endpoints | `http_server_requests_seconds` |
| Intake p99 | 99th percentile of intake response time | `http_server_requests_seconds` histogram |
| Saga terminal ratio | (confirmed + rejected) ÷ placed, over 30 min | `orders_confirmed_total`, `orders_rejected_total` |
| Stuck orders | count of orders past the deadline still non-final | `orders_overdue_nonterminal` gauge |

Two things that trip people up:

- **A 429 is not a failure.** When the intake sheds load on purpose (rate limiter → HTTP 429), that is the
  system working, not breaking. 429s are excluded from the success-rate SLI.
- **REJECTED is not a failure either.** A sold-out trip or a declined card is a *correct* outcome. That is why
  SLO-3 counts "reached a **final** state" (confirmed **or** rejected), not "confirmed". A booking that never
  reaches either — silently stuck with zero 5xx and zero lag — is the real failure, and SLO-3 + SLO-4 are the
  only signals that catch it.

---

## 3. Error budget

A 99% target over 28 days leaves a **1% error budget** — about **7 hours** of full-outage-equivalent per
window, or 1 failed request in 100.

- Only real **5xx** failures spend the budget. **429s do not** (healthy back-pressure).
- While the budget is healthy, releases ship freely.
- The **same SLIs gate the canary** (Argo Rollouts AnalysisRun): a release that *would* burn budget is aborted
  automatically before it reaches users — so the budget is protected at deploy time, not just watched.

---

## 4. What pages us (alerts)

| Alert | Fires when | Why it pages |
|---|---|---|
| Fast burn | success-rate burning budget at **×14.4** (1h & 5m windows) | a sharp regression happening now |
| Slow burn | success-rate burning budget at **×6** (6h & 30m windows) | a steady leak that will exhaust the budget |
| Saga not completing | terminal ratio < 0.99 **or** stuck orders > 0 | accepted bookings aren't finishing |
| Dead letters | DLT depth > 0 | an order failed for good — it won't self-heal |
| CDC stalled | Debezium not RUNNING / slot lost / WAL growing | the outbox→Kafka pipe is broken |

**Why two burn-rate windows.** Fast (×14.4) catches a sudden break within minutes; slow (×6) catches a gentle
leak without paging on a brief blip. Requiring both a long and a short window to agree keeps alerts urgent *and*
precise.

---

## 5. What does NOT page (dashboard only)

| Signal | Why it's not an alert |
|---|---|
| Consumer lag | self-drains when the consumer catches up — a symptom of nothing on its own |
| CPU / memory | a cause, not user pain; a busy CPU with a green success rate is fine |
| 429 rate | the intended load-shed — a hint to scale, not an incident |

**We never page on CPU.** High CPU with a healthy success rate and terminal ratio is not an incident.

---

## 6. Where each signal is measured

- **Intake success + p99** — on the `orders` service (`http_server_requests_seconds`). Deliberately a standard
  Micrometer metric, so it survived the sync→async rework unchanged.
- **Saga terminal ratio + stuck orders** — application counters from `OrderStateMachine` (confirmed/rejected)
  and the `OrderTimeoutSweeper` gauge, pre-aggregated by a recording rule.
- **DLT depth + CDC health** — the Strimzi kafka-exporter and the Debezium/Connect JMX metrics.

Metric cardinality is kept bounded (templated URIs, aggregated lag, grouped by service — never per-pod or
per-partition), so the SLIs stay cheap even while the canary and HPA churn pods.

---

## 7. Status

**Validated live on AKS (Phase 4).** The rules load, the burn-rate and saga alerts evaluate, and the same SLI
queries gate the Phase-5 canary analysis (see `traccia/FASI_PROGETTO.md`).
