# Chaos 07 — Chaos on the canary → Argo Rollouts auto-abort (Fase 5 ✕ Fase 6)

**Proves (Pillar D ✕ Fase 5):** an SLO-gated canary aborts a genuinely bad release **with no human in the
loop**. The Rollouts background AnalysisRun (`analysis.yaml`: intake success-rate, ack p99, Kafka listener
failures — all canary-scoped) is fed the *symptoms* of a bad deploy on the canary only; the controller must
pull the release autonomously while stable keeps serving. This is the **true-positive** counterpart to the
2026-07-03 false-positive in `docs/postmortem.md`.

**Run:** 2026-07-06, live on AKS. *Config adjustment: yes — see "Finding" below (the injection had to change
from a pod-label DB target to delaying all canary egress, and the latency was retuned 1200 ms → 400 ms).*

## Steady state (before)
- `orders` rollout **Healthy at 100% stable**; checkout SLO green; a booking confirms normally.
- A fresh release triggered (image tag → an older `orders` build) → the Rollout ramps `5 → 25 → 50 → 100`,
  gated by the background AnalysisRun. Injection done with the canary at **25%**, canary hash `7dcdcf45c5`.
- Intake traffic ~4 `POST /api/orders`/s so the canary-scoped p99 has real samples (without traffic the
  NaN-proof gate passes trivially and the canary promotes — observed twice while debugging, see Finding).

## The one fault injected
`NetworkChaos` delaying **all egress from the canary pods** by **400 ms ± 40 ms**, scoped to the canary
ReplicaSet's `rollouts-pod-template-hash` (never the stable):
```bash
HASH=$(kubectl -n eurotransit get rollout orders -o jsonpath='{.status.currentPodHash}')
sed "s/REPLACE_WITH_CANARY_HASH/$HASH/" platform/chaos-mesh/07-canary-auto-abort.yaml | kubectl apply -f -
```
The intake ack's DB write is slowed → the canary's `POST /api/orders` p99 blows the 300 ms analysis gate.

## What we observed
1. **Only the p99 gate failed** — exactly the injected symptom. `canary-intake-ack-p99` measurements flipped
   `Failed` (value saturated at the **2 s** histogram ceiling, ≫ the **0.3 s** threshold) at 19:55:11 →
   19:56:41; meanwhile `canary-intake-success-rate` stayed **1.0** (Successful) and `canary-consumer-failures`
   stayed **0** (Successful). The failure was isolated to latency, not correctness.
2. **Autonomous abort.** At `failed (4) > failureLimit (3)` the AnalysisRun went **Failed**
   (`Metric "canary-intake-ack-p99" assessed Failed due to failed (4) > failureLimit (3)`) and the controller
   aborted: rollout → **Degraded (RolloutAborted)**. Time from first failed measurement to abort ≈ **90 s**
   (interval 30 s × the failure limit). **Zero kubectl/commit issued** between injection and abort.
3. **Weights snapped to stable.** TraefikService `orders-weighted`: canary `25 → 0`, stable `75 → 100`; the
   canary ReplicaSet drained.
4. **Stable never suffered.** The chaos only ever selected the canary hash; a `POST /api/orders` on stable
   returned **201 in 0.21 s** right after the abort. No page fired (caught at the gate, far below the
   fast-burn threshold → error budget essentially untouched).

## Verdict
✅ **PASS.** The suspect release was aborted **autonomously** by the canary analysis; only the injected
signal (canary ack p99) failed while success-rate and consumer-health stayed green; traffic snapped back to
100% stable with no human in the loop; stable was never degraded and the money path kept confirming. The
true-positive path claimed by Fase 5 (and left Open in the postmortem) is now proven live.

## For the oral (one breath)
> "We degrade only the canary during a real ramp; its intake p99 blows the analysis gate, and after three bad
> measurements Argo Rollouts pulls the release itself — weights snap back to 100% stable, no human, no page,
> and the money path never notices. That's the true-positive of the same gate that (harmlessly) false-aborted
> on 2026-07-03."

## Finding (config adjustment — also an agent-log / postmortem lesson)
The manifest originally delayed **canary → orders-db** scoped by the `cnpg.io/cluster: orders-db` **pod
label**. On AKS this delayed **nothing**: the app reaches the DB via the **`orders-db-rw` ClusterIP** Service,
so the netem rule (matching pod IPs) missed the ClusterIP-routed packets — the canary p99 stayed ~26 ms, the
gate never tripped, and the canary **auto-promoted twice** before we caught it. Fixes applied to
`platform/chaos-mesh/07-canary-auto-abort.yaml`:
- **Drop the target — delay ALL canary egress** (no destination to match, so the DB write is reliably slowed;
  Kafka/OTLP egress is also slowed, harmless).
- **Retune latency 1200 ms → 400 ms.** Once the delay actually applies it also hits the readiness `db` health
  check; with `readinessProbe.timeoutSeconds=1`, a ≥1 s DB check would trip readiness and abort via
  `ProgressDeadlineExceeded` **before** the p99 gate (wrong mechanism to show). 400 ms blows the 300 ms
  intake-ack p99 gate while the readiness DB check stays under its 1 s timeout — so the **analysis gate** is
  the trigger, as intended.
</content>
