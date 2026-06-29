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

1. **kube-prometheus-stack** is already installed (ns `monitoring`). It must be allowed to **adopt our CRs**:
   its `serviceMonitorSelector`/`ruleSelector` matches the label **`release: kube-prometheus-stack`** (the value
   our template stamps; override with `observability.prometheusRelease`), and its
   `serviceMonitor/ruleNamespaceSelector` must include the `eurotransit` namespace. Verify with:
   ```bash
   kubectl -n monitoring get prometheus -o yaml | grep -iA3 "serviceMonitorSelector\|ruleSelector\|NamespaceSelector"
   kubectl -n eurotransit get servicemonitor,prometheusrule
   # then in the Prometheus UI: Status → Targets show the 5 eurotransit services UP; Status → Rules show the SLO group
   ```
   If the stack uses `*SelectorNilUsesHelmValues: true` (adopts only labelled CRs), our `release` label already
   matches; if it selects by namespace, label the ns or widen the selector. A non-adopted CR is inert (safe).

2. **OpenTelemetry Collector** — deploy as a Deployment+Service **named `otel-collector` in ns `observability`**,
   exposing OTLP **4318** (http). This is deliberate: the app Deployments already point at
   `http://otel-collector.observability.svc:4318/v1/traces`, so matching that name/namespace means **no chart
   change** is needed. The collector batches and exports spans to Tempo.

3. **Grafana Tempo** — install via Helm (pin the version), point the OTel Collector's OTLP exporter at it, and add
   Tempo as a Grafana datasource so traces and metrics share one UI (exemplars).

4. **Dashboards as code** — Grafana sidecar `ConfigMap`s (label `grafana_dashboard: "1"`): money-path overview,
   per-service RED (`http_server_requests_*`), infra USE, **Kafka consumer lag**, CNPG. (Next sub-step.)

**Pin versions** of the stack / Tempo / OTel Collector in this file when installed (reproducibility).

**Still to do:** OTel Collector + Tempo manifests/Helm values; the dashboard ConfigMaps; validate the SLO
targets (99% / 300 ms / 5 s) against a k6 load-test baseline; wire Tempo as a Grafana datasource.

## Follow-ups to apply AFTER the backend-rework / keycloak branch merges into main
These are deliberate temporary shortcuts taken ONLY to avoid a merge conflict with the keycloak branch (which
rewrites `values.yaml` and `deployments.yaml`). The **resource placement is already correct** (ServiceMonitor /
PrometheusRule belong in their own chart template — they are app desired-state reconciled by Argo; the OTel
Collector / Tempo / kube-prometheus-stack belong in `platform/`, install-once). Only the **config wiring** below
is pending:
1. **Add an `observability:` block to `values.yaml`** (alongside `services`/`databases`/`resources`):
   `enabled: true`, `prometheusRelease: kube-prometheus-stack`, `checkoutSuccessTarget: 0.99`,
   `checkoutAckP99Seconds: 0.3`. Then in `templates/observability.yaml` replace the `dig "<key>" <default> $obs`
   reads with plain `.Values.observability.<key>` (and drop the `$obs := .Values.observability | default dict`
   shim). Behaviour is identical; it just becomes discoverable/tunable in the control panel like everything else.
2. **(Optional, cleanliness) parameterise the OTLP tracing endpoint** now hardcoded in `deployments.yaml`
   (`http://otel-collector.observability.svc:4318/v1/traces`) into `values.yaml` (`global.otlpEndpoint`) and
   reference it from the Deployment env. NOT required for correctness: deploying the OTel Collector as
   `otel-collector` in ns `observability` makes the existing hardcoded value resolve as-is.
