# Chaos 07 — Chaos on the canary → auto-abort

**What:** during a real `orders` release ramp (canary at 25%, ~4 req/s of traffic), delay **all egress
from the canary pods only** by 400ms. Proves the SLO-gated canary aborts a genuinely bad release with
no human in the loop — the true-positive counterpart of the 2026-07-03 false abort in `postmortem.md`.

Run 2026-07-06 on AKS:
```bash
HASH=$(kubectl -n eurotransit get rollout orders -o jsonpath='{.status.currentPodHash}')
sed "s/REPLACE_WITH_CANARY_HASH/$HASH/" platform/chaos-mesh/07-canary-auto-abort.yaml | kubectl apply -f -
```

## Results — ✅ PASS

- **Only the injected signal failed:** the canary's intake p99 blew the 300ms gate, while success rate
  stayed 1.0 and consumer failures stayed 0.
- **Autonomous abort in ~90s:** after 4 failed measurements the AnalysisRun went Failed and the
  controller aborted the rollout — weights snapped 25/75 → 0/100, canary drained. Zero commands issued
  between injection and abort.
- **Stable never suffered:** a stable request answered 201 in 0.21s right after; no page fired, error
  budget essentially untouched.

## Finding (the experiment itself had a bug)

The first version delayed canary→DB traffic by matching the **DB pod label** — but the app reaches the
DB through the `orders-db-rw` **ClusterIP**, so the rule matched nothing: the p99 never moved and the
canary **auto-promoted twice** before we noticed. Fixes: delay *all* canary egress (no destination to
match) and retune 1200ms → 400ms so the analysis gate trips before the 1s readiness timeout does.

**Takeaway:** the release gate pulls a bad deploy by itself — and "the chaos was injected" is not "the
chaos had an effect": always check the target metric actually moved.
