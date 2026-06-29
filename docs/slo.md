# SLOs / SLIs for the money path (g03)

> Team-authored. Centred on **checkout** (the critical path). The alerting SLOs are defined on **stable
> Spring Boot Actuator HTTP metrics** (`http_server_requests_seconds*`), which exist regardless of the domain
> model — so they survive the backend rework (UUID/Trip/User). The richer **business** SLI (end-to-end confirm)
> is kept as a dashboard view, not a paging signal, because it is emitted by Orders and may change with the rework.
> The alert rules below are implemented in `deploy/charts/eurotransit/templates/observability.yaml` (a
> `PrometheusRule`); SLI placement was decided 2026-06-10 (see §"Where measured").

## Why these two SLOs (and why we page only on symptoms)
The capstone asks for a **latency SLO** and a **success-rate SLO** for checkout, with the SLIs that measure
them and an **error-budget** statement. We page on **user-visible symptoms** (success-rate / latency burn),
never on a cause like CPU — a cause-based alert fires when nothing is actually broken for the user, and stays
silent when something is. The circuit-breaker/bulkhead/rate-limiter states are **observable** but **not paged**
(an OPEN breaker or a 429 shed is the system *working as designed*).

## SLO 1 — Checkout intake success-rate  *(primary, paged)*
- **What it protects:** a user who calls `POST /api/orders` gets a successful, durable acknowledgement (202).
- **SLI (PromQL):** fraction of intake requests that are **not** a server error, over the endpoint
  (`/api/orders`, `POST`). A **429** (load-shedding) is **NOT** an error — controlled refusal is intended
  behaviour — so only `5xx` count against the budget:
  ```promql
  # good = total - server errors ; ratio = good / total
  sum(rate(http_server_requests_seconds_count{uri="/api/orders", method="POST", status!~"5.."}[$w]))
    /
  sum(rate(http_server_requests_seconds_count{uri="/api/orders", method="POST"}[$w]))
  ```
- **SLO target:** ≥ **99.0%** over a rolling **28-day** window.
- **Error budget:** 1.0% → ≈ **6.72 h** of "all-error-equivalent" per 28 days. We alert on the **burn rate**
  (how fast the budget is being consumed) with multi-window, multi-burn-rate alerts (table below), not on a
  single threshold — this catches both a sudden outage and a slow bleed without flapping.

## SLO 2 — Checkout intake ack latency  *(primary, paged)*
- **What it protects:** the synchronous ack stays fast (the saga proceeds asynchronously, so the user should
  never wait on Inventory/Payments).
- **SLI (PromQL):** p99 of the intake request duration:
  ```promql
  histogram_quantile(0.99,
    sum by (le) (rate(http_server_requests_seconds_bucket{uri="/api/orders", method="POST"}[5m])))
  ```
- **SLO target:** ack **p99 ≤ 300 ms**. Alert when p99 stays above target for a sustained window (10m) — a
  symptom of the intake (not a downstream) being slow.

## SLO 3 — End-to-end checkout confirm  *(secondary, dashboard only — not paged yet)*
- **SLI:** time/oucome from `POST /api/orders` (202) to the order reaching `CONFIRMED`, derived from the
  **business metrics emitted by Orders** (only Orders sees the saga state machine; it cannot be derived from
  HTTP metrics because the flow crosses Kafka). 
- **Status:** dashboard view; **paging deferred** until the backend rework settles the business-metric names.
- **Draft target (to confirm against a load-test baseline):** e2e confirm **p95 ≤ 5 s**.

## Multi-window, multi-burn-rate alerts (success-rate SLO)
`burn = (error ratio over window) / (1 − SLO) = errorRatio / 0.01`. Page when a **fast** and a **slow**
window both burn — fast catches acute outages, slow catches the bleed; requiring both cuts false alarms.

| Severity | Long window | Short window | Burn-rate threshold | Budget consumed before firing |
|---|---|---|---|---|
| page (fast) | 1h | 5m | **14.4×** | ~2% of 28-day budget in ~1h |
| page (slow) | 6h | 30m | **6×** | ~5% over ~6h |

(Both windows must exceed the threshold simultaneously; implemented as two alert rules in the `PrometheusRule`.)

## Where each SLI is measured (decision, 2026-06-10)
- **Intake success-rate & ack latency** (SLO 1/2): at **Orders** via `http_server_requests_seconds*`
  (scraped from `/actuator/prometheus`). The edge view at **Traefik** corroborates "what the user sees".
- **End-to-end confirm** (SLO 3): **business metrics from Orders** (saga state machine).
- **Pipeline backlog** (Kafka consumer lag): **leading indicator** of e2e latency — dashboard/diagnostics
  only, **never paged**.
- **Tracing:** **Tempo** behind an **OTel Collector** gateway; trace context propagated through Kafka headers
  (see `platform/observability/README.md`).

## What we deliberately do NOT alert on
- CPU / memory alone (cause-based).
- Circuit-breaker OPEN, bulkhead full, 429 shedding — these are **designed** controlled-failure behaviours,
  observable on dashboards but not paging signals.

## RTO (for the CloudNativePG primary-failover experiment, chaos #5)
- **Target (draft):** checkout intake success-rate recovers to SLO within ≤ **60 s** of a primary failover
  (RPO = 0 by construction: inventory-db/orders-db use synchronous replication).

## Status / remaining
- ✅ SLIs defined on stable Actuator metrics; error budget + burn-rate policy fixed.
- ✅ Alert rules implemented in `templates/observability.yaml` (`PrometheusRule`), gated by `observability.enabled`.
- ⬜ Grafana SLO panels (dashboards-as-code) — next observability sub-step.
- ⬜ Validate the 99% / 300 ms / 5 s targets against a real load-test baseline (k6) and adjust.
