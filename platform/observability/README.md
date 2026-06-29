# Observability (Pillar D) — pinned decisions + Phase 4 work

Continues Lab05. **Decisions pinned during design (team, 2026-06-10 — "Decisione 11"):**

- **Tracing backend: Grafana Tempo** (not Jaeger). Native Grafana integration — traces,
  metrics and dashboards in one UI for the demo ("where did this order spend its time?") —
  and exemplar support (jump from a latency spike in a metric straight to the trace that
  caused it). The track allows either; Jaeger would add a separate UI to operate.
- **OpenTelemetry Collector** as a gateway in the `observability` namespace; services export
  OTLP (4318) and stay backend-agnostic. One place for batching/sampling config.
- **Metrics:** Micrometer → Prometheus (kube-prometheus-stack) via ServiceMonitor/PodMonitor.
- **Dashboards:** money-path overview, per-service **RED**, infra **USE/Golden-Signals**,
  **Kafka consumer lag** (leading indicator of pipeline latency), CNPG. Provisioned **as
  code** from this repo (Grafana sidecar ConfigMaps) — GitOps applies to dashboards too.
- **Alerts:** only **symptom-based multi-window burn-rate** alerts on the two checkout SLOs
  (fast 1h/5m + slow 6h/30m). CPU/memory/lag never page — they stay on dashboards as
  diagnostics ("alert on burn / user-visible symptoms, not CPU").
- **Logs:** structured JSON on stdout with traceId/spanId injected (log↔trace correlation).
  No mandatory aggregation stack (Loki = optional bonus; the track does not require it).
- **Sampling:** 100% + exemplars (demo-scale traffic; real production would discuss
  tail-based sampling — good point for the oral).
- SLI placement is documented in `docs/slo.md`.

## Phase 4 — status & install steps

**Done (in Git, GitOps-managed by the app chart, gated by `observability.enabled`, default true):**
- **ServiceMonitors** (one per service) + the **checkout SLO `PrometheusRule`** (recording rules + multi-window
  burn-rate alerts + ack-latency alert) live in `deploy/charts/eurotransit/templates/observability.yaml`.
  The SLO is built on the standard Actuator metric `http_server_requests_seconds*` (domain-independent → it
  survives the backend rework). SLI/error-budget/alert policy: `docs/slo.md`.

**To install on the cluster (apply once — platform, not Argo-managed):**

1. **kube-prometheus-stack** (ns `monitoring`) — install it if not already present (`just kube-prometheus-install`,
   release name **`kube-prometheus-stack`**). It must be allowed to **adopt our CRs**: its
   `serviceMonitorSelector`/`ruleSelector` matches the label **`release: kube-prometheus-stack`** (the value our
   template stamps; override with `observability.prometheusRelease`), and its
   `serviceMonitor/ruleNamespaceSelector` must include the `eurotransit` namespace. Verify with:
   ```bash
   kubectl -n monitoring get prometheus -o yaml | grep -iA3 "serviceMonitorSelector\|ruleSelector\|NamespaceSelector"
   kubectl -n eurotransit get servicemonitor,prometheusrule
   # then in the Prometheus UI: Status → Targets show the 6 eurotransit services UP; Status → Rules show the SLO group
   ```
   If the stack uses `*SelectorNilUsesHelmValues: true` (adopts only labelled CRs), our `release` label already
   matches; if it selects by namespace, label the ns or widen the selector. A non-adopted CR is inert (safe).

2. **OpenTelemetry Collector** — deploy as a Deployment+Service **named `otel-collector` in ns `observability`**,
   exposing OTLP **4318** (http). This is deliberate: the app Deployments already point at
   `http://otel-collector.observability.svc:4318/v1/traces`, so matching that name/namespace means **no chart
   change** is needed. The collector batches and exports spans to Tempo.

3. **Grafana Tempo** — install via Helm (pin the version), point the OTel Collector's OTLP exporter at it, and add
   Tempo as a Grafana datasource so traces and metrics share one UI (exemplars).

4. **Dashboards as code** — `dashboards/` holds the dashboard JSON; `dashboards/kustomization.yaml` turns each
   into a `ConfigMap` (label `grafana_dashboard: "1"`, folder `EuroTransit`) the Grafana sidecar auto-loads:
   ```bash
   kubectl kustomize platform/observability/dashboards/   # validate offline (renders the ConfigMaps)
   kubectl apply -k   platform/observability/dashboards/   # install / update
   ```
   Delivered (backed by guaranteed Micrometer metrics, so no empty panels): **RED** (`eurotransit-red.json` —
   per-service rate/5xx/p99 + the checkout intake success-ratio, ack p99 and 429 rate) and **Runtime / golden
   signals** (`eurotransit-runtime.json` — heap, process CPU, live threads, GC pause). The datasource is a
   template variable (not a hardcoded UID) so the dashboards are portable across installs.

**Pin versions** of the stack / Tempo / OTel Collector in this file when installed (reproducibility).

**Still to do:**
- **Kafka consumer-lag** + **CNPG** dashboards already SHIP as `dashboards/eurotransit-kafka.json` and
  `dashboards/eurotransit-cnpg.json` (each with a "prerequisite" note panel), but are **commented out** in
  `dashboards/kustomization.yaml` so we never publish empty-looking panels. Enable them by (a) turning the
  metric source on — Strimzi `kafka-exporter` (`kafka_consumergroup_lag`) or the Micrometer Kafka binder
  (`kafka_consumer_fetch_manager_records_lag`); CNPG `spec.monitoring.enablePodMonitor: true` (`cnpg_*`) — then
  (b) uncommenting the two generators and re-running `kubectl apply -k`.
- Generate steady load with the **k6** money-path script (`platform/k6/money-path.js`) and validate the SLO
  targets (99% / 300 ms) against that baseline.
- Wire **Tempo** as a Grafana datasource (so exemplars jump metric → trace).
- **Live adoption check** (cluster on): Prometheus → Targets shows the 6 services UP, → Rules shows the SLO
  group, and the dashboards appear in the EuroTransit folder.

## Config wiring — DONE (keycloak is merged into main; the temporary shortcuts are gone)
These were deferred only while the keycloak branch was open (it rewrote `values.yaml`/`deployments.yaml`); now
that it is merged they are applied:
1. **`observability:` block in `values.yaml`** (`enabled`, `prometheusRelease`, `checkoutSuccessTarget`,
   `checkoutAckP99Seconds`) — `templates/observability.yaml` reads them via `.Values.observability.*` with a
   single `| default dict` fail-closed guard (no more per-key `dig` defaults).
2. **`global.otlpEndpoint` in `values.yaml`** — `deployments.yaml` injects `MANAGEMENT_OTLP_TRACING_ENDPOINT`
   from it (`$.Values.global.otlpEndpoint`) instead of a hardcoded value, so the OTel Collector endpoint is a
   one-line change. Deploying the Collector as `otel-collector` in ns `observability` still makes it resolve as-is.
