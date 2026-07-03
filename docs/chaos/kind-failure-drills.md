# Kind failure drills — money-path saga

A hands-on runbook for exercising failure on a **local kind cluster**: a money-path service **offline /
unreachable / restarting / rolling-out**, plus the five documented chaos experiments. For each drill it says
exactly **how to inject** it, **what to watch**, and **what the async saga should do**. It doubles as the honest
answer to *"do we have enough logs to see what happens when a dependency is down?"* — see §3.

> **Scope.** kind only, observation only — no code, manifest, or config changes. The graded infra proofs
> (RF=3 broker failover, node/AZ loss, CNPG RTO/RPO) belong on AKS; where a drill can't be faithfully
> reproduced on a single-node/single-broker kind, it says so. The Chaos Mesh manifests under
> `platform/chaos-mesh/` still describe the *retired* sync/breaker design — see §4 before trusting their prose.

The saga under test: Orders orchestrates via a transactional **outbox**; Inventory and Payments consume
commands and reply through their own outbox. Resilience = Kafka buffering + bounded consumer retry + per-service
**DLT** + the **`OrderTimeoutSweeper`** (re-drives stuck orders) + the **`ReservationReconciler`** (TTL
seat-hold backstop). There is **no** circuit breaker anymore.

---

## 1. Setup (once)

### Bring up the money path
```bash
just dev-up          # deploy + restore replicas to their floor
just app-verify      # sanity: pods Ready
```
> ⚠️ **Do not** `just kafka-topics-reset` while the app is running. Deleting topics orphans the consumer
> offsets → on recreate they reset to `earliest` → the whole backlog is reprocessed. Reset topics only with the
> app scaled to zero.

### Open three observation panes
Failure on an async pipeline shows up in three places at once; keep all three open.

**Pane 1 — logs** (plaintext on kind; ECS JSON + Prometheus/Grafana/Tempo are **off** by default per
`values-kind.yaml`). Tail one service across all its replicas:
```bash
kubectl -n eurotransit logs -f -l app.kubernetes.io/name=orders --prefix --max-log-requests=4
# repeat for =inventory and =payments in other tabs (or use `stern -n eurotransit orders` if installed)
```

**Pane 2 — Kafka UI** → <https://kafka-ui.localhost>. Watch: per-topic **backlog**, each consumer group's
**lag + member count** (zero members = that consumer is down), and the **`orders-dlt` / `inventory-dlt` /
`payments-dlt`** topics (a non-zero count = something dead-lettered — see §3 blind spot #1).

**Pane 3 — state + DB.** Saga state and stores (need a JWT — see below):
```bash
curl -k https://app.localhost/api/orders/{orderId}                 # saga state: DRAFT/HELD/PAYING/AUTHORIZED/CONFIRMED/REJECTED
curl -k https://app.localhost/api/inventory/items/{tripCode}       # remaining seats (never negative)
curl -k https://app.localhost/api/payments/authorizations/{orderId} # 0 or 1 authorization per order
```
Outbox backlog + order-status histogram straight from Postgres (reuses the existing DB forwards):
```bash
just dev-forward-all    # orders-db-rw→:5433, inventory-db-rw→:5434, payments-db-rw→:5435
PGPASSWORD=$(kubectl -n eurotransit get secret orders-db-app -o jsonpath='{.data.password}' | base64 -d) \
  psql -h localhost -p 5433 -U orders -d ordersdb \
  -c "SELECT count(*) FROM outbox_events WHERE published_at IS NULL;" \
  -c "SELECT status, count(*) FROM orders GROUP BY status ORDER BY 1;"
```

### Drive steady load
```bash
just loadtest https://app.localhost <jwt>     # K6_VUS / K6_DURATION tunable
```
`POST /api/orders` is secured, so a token is required. Grab one from a logged-in frontend session (copy the
bearer from the browser) or a Keycloak password-grant against the `eurotransit` realm. Without load the SLIs are
flat and nothing interesting burns.

### "Is it reacting?" — log-phrase cheat-sheet
These are the **exact** strings the code emits; grep for them to confirm the system is responding. (Cited to
source so you can trust them; `{}` is a runtime value.)

| What it means | Log phrase (grep target) | Source |
|---|---|---|
| Saga advancing | `added {} leg … — reserve-seats emitted` · `pay initiated — authorize-payment {} emitted` · `AUTHORIZED — confirm-seats fanned out` · `all legs confirmed — capture-payment emitted` | `orders/…/OrderServiceImpl.kt`, `OrderStateMachine.kt` |
| Terminal | `order {} CONFIRMED` · `order {} REJECTED ({})` (reason ∈ SOLD_OUT / PAYMENT_DECLINED / RESERVATION_EXPIRED / EXPIRED_NO_PAYMENT / SERVICE_UNAVAILABLE) | `OrderStateMachine.kt` |
| Malformed/late reply ignored | `order {} unexpected …-result status '{}' — ignored` | `OrderStateMachine.kt` |
| **Stuck orders detected + re-driven** (recover, post-pay) | `re-driving {} stuck order(s) older than the {} deadline` · `order {} re-driven from {} (timeout sweeper)` | `OrderTimeoutSweeper.kt` / `OrderStateMachine.kt` |
| **Checkout window expired** (give up, pre-pay) | `expiring {} booking(s) past the checkout window` · then `order {} REJECTED (EXPIRED_NO_PAYMENT)` or `(SERVICE_UNAVAILABLE)` | `CheckoutExpirySweeper.kt` / `OrderStateMachine.kt` |
| Sweep couldn't run | `order timeout sweep query failed, will retry: {}` · `re-drive of order {} failed, will retry next sweep` | `OrderTimeoutSweeper.kt` |
| **Broker down / publish blocked** | `outbox drain failed, will retry: {}` · `publish of {} ({}) failed, stopping batch to preserve ordering` | `OutboxPublisher.kt` (all 3 services) |
| Cooperative shutdown / restart | `cancelling outbox relay (cooperative shutdown)` · `cancelling order timeout sweeper (cooperative shutdown)`; on the new pod `outbox relay started` · `order timeout sweeper started` | `OutboxPublisher.kt` / `OrderTimeoutSweeper.kt` |
| Concurrency race absorbed | `order {} advanced concurrently (optimistic-lock race lost) — no-op` | `OrderSaga.kt` |
| Seat hold expired + restocked | `expired {} overdue reservations (seats restocked)` | `inventory/…/ReservationReconciler.kt` |

---

## 2. The drills

Each drill: **Inject → Observe → Expect → Cleanup.** Run **one at a time** under steady load, so any effect is
attributable to a single cause.

### Drill 1 — Service OFFLINE (Payments scaled to zero)
The cleanest "dependency is completely gone" test.
- **Inject:** `kubectl -n eurotransit scale deploy/payments --replicas=0`
- **Observe:** intake still returns **202** (Pane 3). In Kafka UI the `authorize-payment` backlog grows and the
  **`payments` consumer group drops to 0 members**. Paid orders stall at `PAYING`. After the `PT2M` deadline, the
  orders log streams `re-driving N stuck order(s) older than the PT2M deadline` every 5s.
- **Expect:** nothing is lost. Recover with `kubectl -n eurotransit scale deploy/payments --replicas=2` → the
  backlog drains, stuck orders re-drive to `CONFIRMED`, and each order has **exactly one** authorization
  (`GET /api/payments/authorizations/{orderId}` — the `UNIQUE(order_id)` guard makes the sweeper's replays
  idempotent, so no double-charge).
- **Cleanup:** replicas back to 2 (above).

### Drill 2 — Service UNREACHABLE but up (network partition)
Distinguishes "down" from "can't talk" — proves liveness won't restart a healthy-but-isolated pod.
- **Inject** (needs `just chaos-install` once): a `NetworkChaos` partition between Payments and Kafka. The
  shipped `04-kafka-partition.yaml` partitions *Orders*↔Kafka; for Payments, adapt its selector to
  `app.kubernetes.io/name: payments`, or reuse drill 5's partition.
- **Observe:** same saga stall as drill 1 — **but the Payments pod stays `Ready`** (`kubectl get pods`). The
  liveness probe hits `/actuator/health/liveness`, which is process-only and deliberately excludes Kafka.
- **Expect:** no restart storm; on heal, consumption resumes and orders converge. This is why liveness must
  never depend on a downstream.
- **Cleanup:** `kubectl delete networkchaos <name> -n eurotransit` (time-based manifests also auto-revert).

### Drill 3 — RESTART / pod-kill mid-flight (Inventory)
The "never oversell under redelivery" proof.
- **Inject** (under load): `kubectl -n eurotransit delete pod -l app.kubernetes.io/name=inventory` (kills both;
  use `--field-selector` or delete one by name to kill just one), or apply
  `platform/chaos-mesh/02-inventory-podkill.yaml` (one pod).
- **Observe:** Kafka redelivers in-flight `reserve-seats` (at-least-once). `GET /api/inventory/items/{tripCode}`
  stays **≥ 0** throughout.
- **Expect:** the atomic conditional `UPDATE` + `UNIQUE(order_id[,product_id])` + `@Version` make a redelivered
  reserve an idempotent replay — **never oversell, never a second hold**. Any concurrency race that loses logs
  `advanced concurrently … — no-op`.
- **Cleanup:** pods self-heal; delete the PodChaos CR if used.

### Drill 4 — ROLLING UPDATE (Orders)
Proves in-flight saga steps survive a deploy with no loss/duplication.
- **Inject** (under load): `kubectl -n eurotransit rollout restart deploy/orders && kubectl -n eurotransit rollout status deploy/orders`
- **Observe:** the terminating pod logs `cancelling outbox relay (cooperative shutdown)` and
  `cancelling order timeout sweeper (cooperative shutdown)`; the new pod logs `outbox relay started` /
  `order timeout sweeper started`. Intake keeps returning 202 the whole time.
- **Expect:** preStop `sleep 5` + `terminationGracePeriodSeconds: 30` + cooperative `scope.cancel()` drain the
  pod cleanly; the **PDB `minAvailable: 1`** keeps a replica serving. Unpublished outbox rows persist across the
  restart and the new pod drains them — **no saga step lost or double-applied.**
- **Cleanup:** none.

### Drill 5 — KAFKA partition / broker (outbox buffering + heal)
- **Inject:** `kubectl apply -f platform/chaos-mesh/04-kafka-partition.yaml` (partitions Orders↔Kafka ~3m, then
  auto-reverts).
- **Observe:** `POST /api/orders` still returns **202** (order + outbox row commit locally). The orders log
  streams `outbox drain failed, will retry`; the outbox backlog (`published_at IS NULL`, Pane 3 psql) grows. On
  heal, the backlog drains **in creation order** and consumer lag returns to ~0.
- **Expect:** convergence with nothing lost and nothing duplicated (outbox re-drain + idempotent consumers).
- **kind caveat:** kind Kafka is a **single broker, `RF=1`, `min.insync.replicas=1`**. A broker *kill* is
  therefore a hard outage with no failover to demonstrate — use the **partition** variant to prove outbox
  buffering. Broker-failover tolerance (RF=3/minISR=2) is an **AKS-only** proof.
- **Cleanup:** `kubectl delete -f platform/chaos-mesh/04-kafka-partition.yaml` (or wait for auto-revert).

### Drill 6 — DB failover (CNPG)
- **kind caveat (read first):** on kind everything runs on **one node** and the DBs are single-instance, so
  there is no true node/AZ loss and **no RTO/RPO to measure** — that is an **AKS-only** graded proof
  (`docs/slo.md` RTO ≤ 60s; `docs/chaos/05-pg-failover.md`). On kind you can at most kill a DB pod to watch the
  app's transient-error handling and the **readiness probe** flip the pod out of the Service endpoints.
- **Inject (kind-safe):** `kubectl -n eurotransit delete pod <cluster>-<n>` for a DB pod (e.g. `orders-db-1`).
- **Observe:** brief write stall surfaces as transient errors in the owning service; readiness flips; requests
  resume once CNPG restarts the instance.
- **Expect:** no committed order/reservation lost; the saga's idempotent re-drive covers any interrupted step.
- **Cleanup:** CNPG self-heals the pod.

---

## 3. Do we have enough logs? — honest verdict

**Yes for the reactions; no for a few leading indicators.** Tailing the three panes, an operator can *see* the
saga detect a down/slow dependency and recover. But three things fail **quietly** and need a workaround until
they're instrumented (out of scope here — see the follow-up note).

### GREEN — clearly observable
| Signal | How you see it |
|---|---|
| Saga progress + terminal outcome | INFO transitions + `CONFIRMED`/`REJECTED` (cheat-sheet) |
| Stuck orders being re-driven | `re-driving N stuck order(s) …` (the system announcing it caught a lost/late step) |
| Broker down / publish blocked | `outbox drain failed, will retry` streaming |
| Clean restart / rolling update | cooperative-shutdown + `…started` phrases |
| Concurrency races | `advanced concurrently … — no-op` |
| Seat-hold expiry + restock | `expired N overdue reservations (seats restocked)` |
| Intake success-rate & ack latency | `http_server_requests_seconds*` — **only if** observability is enabled (see note) |

### BLIND SPOTS — silent today, with a workaround
1. **DLT routing is not logged at the app layer.** When a message exhausts its 3 retries, Spring's
   `DeadLetterPublishingRecoverer` ships it to `*-dlt` with **no app log naming the order/topic/cause** (only
   Spring-Kafka's internal WARN). → **Workaround:** watch the `*-dlt` topic counts in Kafka UI; a non-zero count
   means something dead-lettered — consume the record and read the exception from its headers.
2. **Outbox backlog depth has no gauge.** → **Workaround:** the Pane-3 psql
   `SELECT count(*) FROM outbox_events WHERE published_at IS NULL;` (per DB).
3. **Consumer lag is not exported to Prometheus** (the SLO doc calls it a leading indicator, but it isn't
   wired). → **Workaround:** Kafka UI consumer-group view — lag + member count.
4. **Non-terminal order count has no gauge.** → **Workaround:** `SELECT status, count(*) FROM orders GROUP BY
   status;` — a rising HELD/PAYING/AUTHORIZED pile is the early warning the sweeper only surfaces at the
   2-minute mark.

> **Observability is off on kind by default.** No Prometheus/Grafana/Tempo, and logs are plaintext not ECS JSON
> (`values-kind.yaml`). To get dashboards, burn-rate alerts, and traces on kind: `just observability-install`,
> then deploy with `--set observability.enabled=true`. Otherwise, kind observation = **`kubectl logs` + Kafka UI
> + psql** (the three panes above). Prod (base values) keeps observability on.

---

## 4. Known doc drift — flag before trusting the chaos prose

The following still describe the **retired sync/circuit-breaker world** and have **not** been updated for the
async cutover:
- `platform/chaos-mesh/01-payments-latency.yaml` + `docs/chaos/01-payments-latency.md` — assert a breaker
  **OPEN**s and parks the order in `PAYMENT_PENDING` with **bulkhead** isolation. None of that exists now.
- `docs/chaos/test-traceability.md` and `docs/capstone-dod.md` chaos table — map experiments to **deleted** tests
  (`PaymentsCircuitBreakerTest`, `BulkheadIsolationTest`, `OrderRecoverySweeperTest`, …) and call the Chaos Mesh
  manifests "planned" (they exist).

For the money path, **experiment 01's latency hypothesis is superseded** by this playbook: sustained Payments
latency/outage is now absorbed by Kafka buffering + bounded consumer retry + DLT + the timeout sweeper, **not**
a breaker. De-staling those three documents is a **follow-up**, deliberately out of scope for this
playbook-only pass.

---

## Quick reference

```bash
# inject
kubectl -n eurotransit scale deploy/payments --replicas=0            # 1: offline   (undo: --replicas=2)
kubectl apply -f platform/chaos-mesh/04-kafka-partition.yaml         # 2/5: unreachable / kafka partition (auto-reverts)
kubectl -n eurotransit delete pod -l app.kubernetes.io/name=inventory # 3: pod-kill  (or 02-inventory-podkill.yaml)
kubectl -n eurotransit rollout restart deploy/orders                 # 4: rolling update
kubectl -n eurotransit delete pod orders-db-1                        # 6: db pod loss (kind-safe subset)

# observe
kubectl -n eurotransit logs -f -l app.kubernetes.io/name=orders --prefix --max-log-requests=4
open https://kafka-ui.localhost                                      # backlog / lag / members / *-dlt
curl -k https://app.localhost/api/orders/{orderId}                   # saga state
```
