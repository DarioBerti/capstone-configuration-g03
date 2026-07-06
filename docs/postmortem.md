# Blameless postmortem — the first live canary auto-abort

> **Blameless** means we look at the system and its signals, not at people. Here the safety mechanism did its
> job perfectly — it protected users with zero human action. The problem was the *signal* it trusted.

**The incident.** The first real Argo Rollouts canary on AKS **auto-aborted an `orders` release**. This is
exactly the "bad deploy caught automatically" scenario progressive delivery exists for — except this time the
"bad deploy" signal was a **false alarm**. (Source: `agent-log.md` #10 and the 2026-07-03 fix commits.)

- **When:** 2026-07-03. The release was blocked for a couple of minutes, auto-recovered, and the fix landed the
  same day.
- **User impact:** **none.** No orders lost, never-oversell held, no alert fired, error budget essentially
  untouched. The only cost was one blocked release and some engineer time.

---

## What happened, in one paragraph

We shipped a normal release (an image-tag bump). Argo Rollouts turned it into a weighted canary and started a
background Prometheus analysis on the **canary pods only**. Within ~90 seconds the analysis marked the
success-rate check as failed four times in a row and aborted the rollout — traffic snapped back to 100% stable,
untouched. But the canary was actually healthy: the success-rate check had been fed a **`NaN`** and misread it
as a failure.

---

## Timeline (UTC)

| Time | Event |
|---|---|
| T0 | `orders` image-tag bump merged → Argo CD syncs → the canary starts ramping (5% …) |
| ~T0+30s | canary serves a few requests, then the smoke-test token expires mid-ramp → its 401s land under `uri="UNKNOWN"`, outside the SLI query |
| ~T0+1m | over the 2-minute window the success-rate query goes to **0/0 = NaN**; `NaN ≥ 0.99` is false → the check reads "Failed" |
| ~T0+1.5m | 4 consecutive failures → analysis Failed → **controller aborts on its own**; TraefikService weights → 100/0 |
| ~T0+1.5m | recovery is the abort itself — stable was never touched; checkout SLO green throughout, **no page** |
| same day | root cause found, NaN-guard fix committed, canary re-run → clean ramp to 100% |

---

## Root cause

The success-rate check guarded the no-traffic case with `… or vector(1)`. That guard only kicks in when the
query returns an **empty result** (no data series at all).

But the canary *had* served a handful of requests, so its series existed. When the smoke-test token expired, the
resulting 401s were recorded under `uri="UNKNOWN"` — which the SLI query doesn't select — so over the 2-minute
window **both the numerator and the denominator dropped to 0**. `0/0 = NaN`, and `or vector(1)` cannot replace a
`NaN` (it's a present value, not an empty result). `NaN ≥ 0.99` is false, so the check failed four times and the
rollout aborted.

**The mechanism worked exactly as designed — it was handed a lying signal.**

---

## What went well vs. what didn't

**Went well.** The core Phase-5 claim was proven live: an SLO-gated canary aborts a suspect release
**by itself**. Stable never degraded, blast radius was limited to the canary's small traffic share for under two
minutes, and there was no page and no customer impact.

**Didn't.** The signal was fragile. PromQL has **two** "no data" shapes — an empty result *and* a `NaN` sample —
and the gate only handled the first. A harmless combination (a trickle of canary traffic + an expired smoke
token) looked like failure. A false abort blocks a good release, and if it kept happening unexamined, we'd stop
trusting the gate — the "cried wolf" failure mode for automated rollbacks.

---

## Action items

| Action | Owner | Status |
|---|---|---|
| NaN-proof every canary check (`isNaN(...) || <slo test>`) so a 0/0 window means "no evidence of failure", not "failure" | Mattia | **Done** (2026-07-03) |
| Make the smoke-test token outlive the ramp (or exclude 401/`uri="UNKNOWN"` from the SLI) so canary traffic can't create a 0/0 window | Emanuele | Open |
| Prove the **true-positive** path too — chaos 07: inject latency into the canary and confirm the gate aborts a genuinely bad deploy | Mattia | **Done** (2026-07-06, live — see below) |
| Harden the chaos-07 injection (see the follow-up finding below) | Mattia | **Done** (2026-07-06) |
| Add "the two no-data shapes" to the release-gate review checklist | Team | Open |

---

## Follow-up (2026-07-06): the true-positive, proven live

The 03/07 incident was a *false* abort. On 2026-07-06 we closed the loop and proved the *true* abort with chaos
experiment 07 (full write-up: `chaos/07-canary-auto-abort.md`).

**What we did.** During a real `orders` canary at 25% (under ~4 req/s), we injected network latency into **only**
the canary pods. The canary's `POST /api/orders` p99 blew the 300 ms gate; after 4 failures (~90 s) the
controller **aborted on its own** — weights `25/75 → 100/0`, canary drained, and stable kept serving `201` in
0.21 s the whole time. No human action, no page.

**The key contrast.** This time only the *injected* signal failed: success-rate stayed 1.0 and consumer-failures
stayed 0. That is the mirror image of 03/07 (where a lying success-rate signal caused the abort). Together the
two runs show both halves: the gate aborts a genuinely bad release, and — after the NaN fix — no longer aborts a
healthy one.

**A bonus lesson (the experiment itself had a hidden bug).** The chaos manifest first delayed traffic from the
canary to the DB by matching the **DB pod label**. But on AKS the app reaches the DB through the `orders-db-rw`
**ClusterIP**, so the pod-IP netem rule matched nothing — the delay did nothing, the p99 never moved, and the
canary **auto-promoted twice** before we noticed. Fix: delay **all** canary egress (no destination to match) and
drop the latency from 1200 ms to 400 ms so it stays under the 1 s readiness timeout — that way the **analysis
gate** trips it, not a probe timeout. *Lesson: "the chaos injected successfully" is not "the chaos had an
effect" — always check the target metric actually moved.*

---

_Blameless close: our automation prevented a bad outcome and behaved exactly as designed. The work is to harden
the **signal** so it stops firing on non-failures — not to distrust the mechanism that kept users safe._
