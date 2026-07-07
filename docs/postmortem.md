# Postmortem

## What happened

**2026-07-03.** We shipped a normal `orders` release. Argo Rollouts started a canary and checked its
success rate on Prometheus. After ~90 seconds the check failed 4 times in a row, so the rollout
**aborted itself**: traffic snapped back 100% to the stable version.

Problem: the canary was actually **healthy**. The abort was a false alarm.

**User impact: none.** Stable was never touched, no order lost, no alert. Cost: one blocked release.

## Why it happened

The success-rate query is "good requests / total requests" over a 2-minute window. In that window the
canary got **zero requests counted by the query** (the smoke-test token had expired, so its requests
fell outside the metric). Zero divided by zero is **NaN**, and `NaN ≥ 0.99` is false → the check reads
"failed".

We *had* a guard for "no traffic", but it only covers the case where the query returns **nothing at
all**. `NaN` is a value that exists, so the guard didn't kick in. In short: PromQL has **two** shapes
of "no data" — empty result and NaN — and we had handled only one.

## Fix

Same day: every canary check is now NaN-proof — a 0/0 window means "no evidence of failure", not
"failure". The canary was re-run and promoted cleanly.

## Follow-up (2026-07-06): proving the opposite case

The incident showed the gate can *wrongly* abort. Chaos experiment 07 proved it also *rightly*
aborts: during a real canary we injected latency into the canary pods only. Its p99 blew the 300 ms
limit and the controller aborted on its own — stable kept answering fast the whole time, no human
action.

Together the two runs show both halves: the gate blocks a genuinely bad release, and (after the NaN
fix) no longer blocks a healthy one.

**Bonus lesson from chaos 07:** the first version of the injection silently did nothing (it targeted
the DB pod IP, but traffic goes through the service IP), and the canary auto-promoted twice before we
noticed. "The chaos was injected" is not "the chaos had an effect" — always check the target metric
actually moved.

## Lessons (the exam takeaways)

1. **The mechanism worked; the signal lied.** Automated rollback is only as good as the metric it watches.
2. **0/0 = NaN is not "no data".** Guard both no-data shapes, or low-traffic canaries produce false aborts.
3. **False aborts erode trust.** If the gate cries wolf, people stop believing it — that kills automated rollback.
4. **Prove both directions:** that the gate aborts a bad release (chaos 07) *and* lets a good one through.

## Action items

| Action | Status |
|---|---|
| NaN-proof all canary checks | **Done** (2026-07-03) |
| Prove the true-positive abort live (chaos 07) | **Done** (2026-07-06) |
| Keep the smoke-test traffic inside the SLI (token must outlive the ramp) | Open |
| Add "the two no-data shapes" to the release-gate checklist | Open |
