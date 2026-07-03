# Experiment 07 — Chaos on the canary → Argo Rollouts auto-abort (Fase 5 ✕ Fase 6)

**Maps to:** Pillar D "proof under failure" ✕ Fase 5 progressive delivery. The Rollouts canary analysis
(`analysis.yaml`: intake success-rate, ack p99, Kafka listener failures — canary-scoped) claims it will
abort a bad release **with no human in the loop**. This experiment injects the bad release's *symptoms* and
proves the claim live. It is also the natural **postmortem/demo centerpiece** (a "bad deploy at 3am" story).

> **Prereqs:** Argo Rollouts + analysis enabled (i.e. Prometheus present → **AKS**, or kind with the
> kube-prometheus-stack installed). Requires the Fase-5 PR merged.

- **Steady state (SLIs):** rollout `orders` Healthy at 100% stable; checkout SLO green; a fresh rollout in
  progress ramps 5→25→50 gated by the background AnalysisRun.
- **Hypothesis:** degrading ONLY the canary pods during the ramp makes the canary-scoped analysis fail its
  ack-p99 gate within ~3 failed measurements (≈90 s), upon which the controller **aborts autonomously**:
  TraefikService weights snap to `100/0`, the canary ReplicaSet drains, the rollout goes `Degraded
  (RolloutAborted)` — and the *user-facing* SLO barely notices, because only the canary's weight share
  (≤ 25%) was exposed, for less than two minutes. Stable pods are never touched.
- **Blast radius / one variable:** network delay canary-pods → orders-db only, scoped by the canary
  ReplicaSet's `rollouts-pod-template-hash` label (the only label distinguishing canary from stable pods).
- **Method:**
  1. start a release: bump `services.orders.image.tag` (commit → Argo CD → the Rollout starts stepping);
  2. grab the canary hash while the ramp is at a low weight:
     `HASH=$(kubectl -n eurotransit get rs -l app.kubernetes.io/name=orders \
        -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash} {.spec.replicas}{"\n"}{end}' | awk '$2>0' | tail -1 | cut -d' ' -f1)`
     (or read it off `kubectl argo rollouts get rollout orders`);
  3. substitute it in the manifest and apply:
     `sed "s/REPLACE_WITH_CANARY_HASH/$HASH/" platform/chaos-mesh/07-canary-auto-abort.yaml | kubectl apply -f -`
  4. watch: `kubectl argo rollouts get rollout orders --watch` + `kubectl -n eurotransit get analysisrun`.
  Manifest: `platform/chaos-mesh/07-canary-auto-abort.yaml` (delay 2 s canary→orders-db → the POST ack,
  whose write path crosses the DB, blows the 300 ms p99 gate decisively).

## Observation (fill during the run)

- The AnalysisRun's `canary-intake-ack-p99` measurements flip to `Failed` (capture `kubectl describe
  analysisrun`); at `failureLimit` (3) the run is `Failed` and the rollout `Degraded — RolloutAborted`.
- TraefikService weights: `50/50` (or wherever the ramp was) → `100/0` with **no kubectl/commit issued**.
- Overall checkout SLO: bounded dip proportional to the canary weight (compute the burn: it must stay well
  under the fast-burn page threshold) — the analysis caught it before the alert would have.
- Cleanup: `kubectl delete networkchaos canary-db-latency -n eurotransit`; the next good release
  (or `kubectl argo rollouts retry orders` after removing the chaos) completes normally.

<screenshots/links — this run IS the demo material>

## Conclusion — PASS criteria
- [ ] Abort happened autonomously (zero human actions between injection and weights back at 100/0).
- [ ] Stable never degraded; total SLO burn ≤ the canary's weight share for ≤ ~2 min; no page fired.
- [ ] Post-abort state clean: stable serving 100%, canary drained, next release unblocked.
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
