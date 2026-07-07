# Chaos 01 — Latency into Payments (a slow downstream never reaches the user)

**Proves (Pillar C, async form):** a slow Payments consumer is absorbed as **saga latency**, not a user-facing
failure. The intake ack SLO stays green because the slow step is **behind Kafka**, not on the request thread.
This is the async replacement for the retired Orders→Payments circuit breaker — and it does the job *better*
(the user sees nothing).

**Run:** 2026-07-06, live on AKS, Chaos Mesh `NetworkChaos`. *Config adjustment: none (network delay, not pods).*

## Steady state (before)
- Intake ack fast; catalog browse ~0.15 s; orders reach terminal in ~5 s; consumer lag ~0; DLTs empty.

## The one fault injected
```bash
kubectl apply -f platform/chaos-mesh/01-payments-latency.yaml   # NetworkChaos delay 3s ±200ms, BOTH directions,
                                                                 # payments ↔ Kafka brokers only, 5m (auto-reverts)
```
Only the Payments↔Kafka path is delayed — Payments' DB and every other service are untouched (one variable).

## What we observed (during the 3 s latency)
| Signal | Value | Meaning |
|---|---|---|
| `POST /api/orders` (create draft) | **0.22 s** | intake unaffected (doesn't touch Payments) |
| `POST /{id}/pay` **ack** | **0.15 s** | 202 returns immediately — the request thread never waits on the slow step |
| catalog browse | **0.21 s** | different service/DB → completely unaffected |
| add-leg → leg | RESERVED, 0.28 s | Inventory not delayed |
| order → terminal | **CONFIRMED after 21 s** (vs ~5 s) | the delay surfaced as **saga slowness**, and the order STILL confirmed |

So the downstream failure showed up as extra async latency (payments +3 s/hop), **never** as a user-visible error
or a lost order. It confirmed inside the 2-minute sweeper deadline, so no re-drive was even needed; anything that
did cross PT2M would be re-driven by `OrderTimeoutSweeper` (idempotent — `UNIQUE(order_id)` → no double-charge).

## Verdict
✅ **PASS.** Intake ack + catalog stayed fast (well within the 300 ms SLO) throughout; the order confirmed
(slower but correct); no lost order, no double-charge, no DLT (latency is not an error → nothing poisoned).
Hypothesis held; nothing changed.


