# Blameless postmortem — first live canary auto-abort (false positive)

> **Blameless: the focus is the system and the signals, not individuals.** The Argo Rollouts canary
> safety mechanism did exactly its job — it protected users with **zero human action**; the defect
> was in the *signal* the gate trusted, not in anyone's judgment.
>
> **Incident chosen.** The first real Argo Rollouts canary AnalysisRun on AKS auto-aborted an
> `orders` release. This is the live occurrence of the "bad deploy at 3am" scenario the
> progressive-delivery gate exists for (chaos experiment 07) — except here the "bad deploy" signal
> was a **false positive**. Sourced from `docs/agent-log.md` #10 (full log #24) and the 2026-07-03
> fix commits. *When you run a real bad-deploy injection live (chaos 07) at the demo, either update
> this file with that run or add a second postmortem — the structure is identical.*

- **Date / duration:** 2026-07-03. Release blocked for a few minutes (auto-recovered); root-cause + fix landed the same day.
- **Summary:** A routine `orders` image-tag bump started a canary ramp; the background analysis
  aborted it at step 0 and snapped traffic back to 100% stable — automatically, no human in the
  loop. Users saw nothing. The abort was a **false positive** caused by a `NaN` in the
  intake-success-rate query.
- **Impact:** **No customer impact.** No orders lost; the **never-oversell invariant held** (the new
  revision never carried real production traffic — the canary was pulled at ≤ its ramp weight for
  < 2 min; stable, unchanged, served throughout). **No page fired** — it was caught at the canary
  gate, far below the fast-burn threshold — so the **error budget was essentially untouched**. The
  only cost was one blocked release and engineer time to diagnose.

## Timeline (UTC)
| Time | Event | Signal that showed it |
|---|---|---|
| T0 | `services.orders.image.tag` bump merged → Argo CD syncs → the `orders` Rollout starts stepping (5 → …) | `kubectl argo rollouts get rollout orders` = **Progressing** |
| ~T0+30s | canary serves a handful of requests; the smoke-test token then expires mid-ramp → 401s recorded under `uri="UNKNOWN"` (outside the SLI selector) | intake-success-rate numerator **and** denominator drop to 0 over the 2 m window |
| ~T0+1m | `canary-intake-success-rate` measurements flip to **Failed** (`0/0 = NaN`; `NaN >= 0.99` is false) | `kubectl describe analysisrun` → measurement status **Failed** |
| ~T0+1.5m | 4 consecutive Failed → AnalysisRun **Failed** → controller **aborts autonomously** | Rollout = **Degraded (RolloutAborted)**; TraefikService weights → **100/0** with no commit/kubectl issued |
| ~T0+1.5m | recovery is the abort itself — stable is already at 100% and was never touched | checkout SLO green throughout; **no burn-rate alert fired** |
| same day | root-caused + NaN-guard fix committed; canary re-triggered → clean ramp to 100% | AnalysisRun **Successful** ×N under live traffic |

## What happened
**Steady state:** `orders` Healthy at 100% stable, checkout SLO green. We shipped a normal release
(an image-tag bump), which Argo Rollouts turns into a weighted canary ramp gated by a background
Prometheus AnalysisRun. The gate runs the **same SLIs as `slo.md`** — intake success-rate, ack p99,
and Kafka listener failure-rate — but **scoped to the canary pods** (via the
`rollouts-pod-template-hash` label).

The intake-success-rate `successCondition` guarded the no-traffic case with `… or vector(1)`, which
only substitutes a value when the query result is an **empty vector** (no series at all). But the
canary had already served a handful of requests, so its series **existed**. When the smoke-test
token expired mid-ramp, the resulting 401s were recorded under `uri="UNKNOWN"` — outside the SLI
selector — so over the 2-minute rate window **both** the numerator and the denominator went to 0.
`0/0 = NaN` — a *present* sample that `or vector(1)` cannot replace — and `NaN >= 0.99` is false.
Four consecutive Failed measurements tripped the analysis `failureLimit`, and the controller
aborted the rollout. **The mechanism behaved perfectly; it was fed a lying signal.**

## Detection
The canary AnalysisRun surfaced it **directly** — this is the gate working as designed, so no
downstream alert was needed and none fired. `kubectl argo rollouts get rollout orders` showed
**Degraded (RolloutAborted)**; `kubectl describe analysisrun` showed the `canary-intake-success-rate`
measurements as **Failed**. Time-to-detect ≈ the analysis interval × 4 (≈ 1–2 min).

## Recovery
**Automatic — the abort *is* the recovery.** Weights snapped to `100/0`, the canary ReplicaSet
drained, and stable (unchanged, healthy) kept serving 100% of traffic the whole time. **Observed
RTO ≈ the abort latency (< ~2 min), with zero human actions in the loop** — well inside any
release-safety target. The follow-up code fix (below) landed the same day; a re-triggered canary
then ramped cleanly to 100%.

## What went well / what didn't
**Went well.** The core Phase-5 claim was proven **live**: an SLO-gated canary aborts a suspect
release **autonomously**; stable never degraded; the blast radius was bounded to the canary's
weight share for < 2 min; no page, no customer impact, never-oversell untouched.

**Didn't.** The *signal* was fragile. The gate handled only one of PromQL's two "no data" shapes
(empty vector) and was blind to the other (a `NaN` sample), so a benign combination — a trickle of
canary traffic plus an expired smoke token — read as "failure". A false-positive abort blocks a
good release, and if it recurred unexamined it would erode trust in the gate (the "boy who cried
wolf" failure mode for automated rollbacks).

## Action items
| Action | Owner | Status |
|---|---|---|
| NaN-proof **every** canary `successCondition` (`isNaN(result[0]) \|\| <slo test>`) so a `0/0` window counts as "no evidence of failure", not "failure" | Mattia | **Done** (2026-07-03 — commit `fix(fase5): NaN-proof the canary analysis gates`) |
| Make the smoke-test token outlive the ramp (or exclude `uri="UNKNOWN"` / 401 from the intake SLI) so canary traffic can't manufacture a `0/0` window | Emanuele | Open |
| Prove the **true-positive** path too: run chaos exp. 07 (inject latency into ONLY the canary during a live ramp) and confirm the gate aborts a genuinely bad deploy | Mattia | **Done** (2026-07-06 — live on AKS; the canary ack-p99 gate aborted a genuinely bad canary, stable untouched. See `docs/chaos/07-canary-auto-abort.md` and the follow-up below) |
| Harden the chaos-07 injection: a NetworkChaos `target` by the orders-db pod label doesn't intercept ClusterIP-routed DB traffic → delay all canary egress instead, and retune the latency under the 1 s readiness timeout | Mattia | **Done** (2026-07-06 — `platform/chaos-mesh/07-canary-auto-abort.yaml`) |
| Add "the two no-data shapes" (empty vector vs `NaN`) to the release-gate review checklist | Team | Open |

## Follow-up (2026-07-06): the true-positive path, proven live

The 03/07 incident above was a **false** abort. On 2026-07-06 we closed the loop by proving the **true**
abort — chaos experiment 07, live on AKS (full write-up: `docs/chaos/07-canary-auto-abort.md`).

- **What we did.** During a real `orders` canary ramp (canary at 25%, under ~4 req/s of intake), we injected
  network latency into **only** the canary pods. The canary's `POST /api/orders` p99 blew the 300 ms analysis
  gate; after `failed (4) > failureLimit (3)` (~90 s) the controller **aborted autonomously** → rollout
  `Degraded (RolloutAborted)`, TraefikService weights `25/75 → 100/0`, canary drained, **stable served 201 in
  0.21 s throughout** — zero human actions, no page.
- **Crucially, only the injected signal failed.** `intake-success-rate` stayed 1.0 and `consumer-failures`
  stayed 0 — the opposite of the 03/07 false positive, where a *lying* success-rate signal (`0/0 = NaN`)
  caused the abort. Together the two incidents show both halves: the gate aborts a genuinely bad release, and
  (post NaN-fix) no longer aborts a healthy one.
- **New lesson (the experiment itself had a latent defect).** The chaos manifest originally delayed
  `canary → orders-db` scoped by the DB **pod label**; on AKS the app reaches the DB via the `orders-db-rw`
  **ClusterIP**, so the netem rule (pod-IP match) intercepted nothing — the delay was a no-op, the p99 never
  moved, and the canary **auto-promoted twice** before we noticed. Fix: delay **all** canary egress (no
  destination to match) and retune the latency (1200 ms → 400 ms) to stay under the 1 s readiness-probe
  timeout, so the **analysis gate** (not `ProgressDeadlineExceeded`) is the trigger. *Lesson: "the chaos
  injected successfully" (`AllInjected=True`) is not "the chaos had an effect" — verify the target metric
  actually moved.* Recorded in the agent-log.

---
_Blameless close: our automation prevented a bad outcome and behaved exactly as designed. The work
is to harden the **signal** so it stops firing on non-failures — not to distrust the mechanism that
kept users safe. The 2026-07-06 follow-up adds the missing half: the same gate, proven to abort a genuinely
bad release — again with no human in the loop._
