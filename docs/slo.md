# Checkout SLOs — EuroTransit (g03)

The formal service-level objectives for the **checkout money path** (the user-visible critical path). This is
the deliverable extract; the full rationale lives in the config README §4 (Pillar D) and `design.md §4-D`, and
the objectives are **wired live** as the `eurotransit-checkout-slo` and `eurotransit-saga-slo` PrometheusRules
(rendered by `deploy/charts/eurotransit/templates/observability.yaml`, evaluated by kube-prometheus).

Guiding rule: **we page only when a human is needed AND users are suffering now.** Everything else is a
dashboard signal, not an alert.

## 1. What we protect

A customer's booking reaching a terminal state correctly and promptly: the synchronous **intake** (`POST
/api/orders` create, `POST /{id}/legs`, `POST /{id}/pay`) must be fast and available, and the **async saga**
must drive every accepted booking to a terminal state (CONFIRMED or a legitimate REJECTED) in bounded time.

## 2. SLIs (the signals)

| SLI | Definition | Source |
|---|---|---|
| **Intake success-rate** | non-5xx responses / total on the intake endpoints. A **429 is NOT an error** (deliberate load-shed, §resilience). | `http_server_requests_seconds*` (standard Micrometer — survives the async rework) |
| **Intake ack latency (p99)** | p99 of the synchronous intake response time | `http_server_requests_seconds*` histogram |
| **Saga terminal-ratio** | `checkout_saga:terminal_ratio:rate30m` = (confirmed + rejected) / placed, denominator `offset 3m` (> the 2m sweeper deadline). **Terminal, not confirmed** — SOLD_OUT / PAYMENT_DECLINED are correct saga outcomes, not failures. | app counters `orders_confirmed_total`, `orders_rejected_total{reason}` |
| **Stuck orders** | orders sitting non-terminal past the deadline (total-stall symptom, visible even at zero traffic) | `orders_overdue_nonterminal` gauge (orders timeout sweeper) |

Why the saga SLI exists: after the async cutover a `202`/ack no longer means "order completed" — a booking can
stall with zero 5xx and zero lag. The terminal-ratio + the stuck-orders gauge are the only true user-visible
completion signals.

## 3. SLOs (targets)

- **Intake success-rate ≥ 99%**, measured over a **28-day** rolling window.
- **Intake ack p99 ≤ 300 ms**.
- **Saga terminal-ratio ≥ 0.99** (rolling 30 m).
- **`orders_overdue_nonterminal` = 0** (any sustained non-zero is a stall).

## 4. Error budget

A 99% / 28-day success-rate objective allows a **1% error budget** over the 28-day window (≈ 7.2 h of
full-failure-equivalent, or 1 in 100 intake requests). The budget is consumed by real 5xx failures only —
**429s do not consume it** (they are a healthy back-pressure response, not a failure). When the budget burns
too fast the burn-rate alerts fire; when it is healthy, releases proceed (the same SLIs gate the Argo Rollouts
canary AnalysisRun, so a release that would burn budget is auto-aborted before it ships).

## 5. Alerting — burn-rate, multi-window

| Alert | Condition | Severity |
|---|---|---|
| Fast burn | success-rate SLO burning at **×14.4** over **1h / 5m** windows | page |
| Slow burn | success-rate SLO burning at **×6** over **6h / 30m** windows | page (slower) |
| Saga not completing | `terminal-ratio < 0.99` **or** `orders_overdue_nonterminal > 0` | page |
| Dead letters | `eurotransit_dlt:depth:sum > 0` (orders permanently failed, won't self-heal) | page |
| CDC stalled | Debezium connector not RUNNING / replication slot lost-inactive / WAL growing | page |

Multi-window (fast + slow) keeps alerts both **urgent** (fast catches a sharp regression) and **precise** (slow
avoids paging on a brief blip).

## 6. What does NOT page (dashboard-only)

- **Consumer lag** (`kafka_consumergroup_lag`) — self-drains once the consumer recovers; diagnostic, not a
  symptom.
- **CPU / memory / Debezium lag** — a cause or by-design behaviour, not user pain.
- **429 rate** — the intended load-shed; a signal to scale, not an incident.

Never alert on CPU: a saturated CPU with a healthy success-rate and terminal-ratio is not an incident.

## 7. Where each SLI is measured

- **Intake success-rate + ack p99** — `http_server_requests_seconds*` on the `orders` service (edge ack is also
  visible at Traefik); a standard metric chosen so the SLI survived the sync→async rework unchanged.
- **Saga terminal-ratio + stuck orders** — application metrics emitted by `OrderStateMachine` terminal
  transitions (`orders_confirmed_total` / `orders_rejected_total{reason}`) and the `OrderTimeoutSweeper` gauge;
  pre-aggregated by the `checkout_saga:terminal_ratio:rate30m` recording rule.
- **DLT depth / CDC health** — the Strimzi kafka-exporter (DLT offsets) and the Debezium/Connect JMX metrics
  (`platform/strimzi/monitoring.yaml`, `platform/debezium/monitoring.yaml`).

## 8. Status

Validated LIVE on AKS (Phase 4): the rules load, the burn-rate and saga alerts evaluate, and the same SLI
queries gate the Phase-5 canary analysis (see FASI_PROGETTO §Phase 4/5). Cardinality is bounded (templated
URIs, aggregated lag, panels grouped by service/job — never per-pod/per-partition) so the SLIs stay cheap under
canary/HPA churn.
</content>
