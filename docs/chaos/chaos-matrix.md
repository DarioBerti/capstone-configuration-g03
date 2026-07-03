# Chaos experiment matrix — money-path saga

Structured companion to [`kind-failure-drills.md`](./kind-failure-drills.md). That doc is the hands-on
runbook (setup, the three observation panes, the log-phrase cheat-sheet, and six worked drills). **This doc is
the map**: every fault we care about, as a falsifiable experiment, so we can see coverage at a glance and record
results.

Each row is a chaos experiment in the proper sense: a **steady-state hypothesis** (an invariant that must keep
holding), a **fault injection** (turn a pod / broker / DB / dependency off), and a **pass criterion** that can
only be *disproved* — if the invariant breaks, the experiment failed and we found a real bug.

> **Scope discipline (inherited from the runbook).** Rows are **kind-reproducible** unless flagged **AKS-only**.
> kind is single-node, single-broker (`RF=1`, `minISR=1`), single-node DBs — so broker failover and true
> node/AZ/CNPG RTO-RPO proofs *cannot* be faithfully shown on kind and belong on AKS. Observability is off on
> kind by default: observation = `kubectl logs` + Kafka UI + psql (see runbook §1).

---

## 1. Steady-state invariants (what every experiment must not break)

These are the properties chaos is trying to violate. Every experiment below lists which ones it puts at risk;
the pass criterion is "these still hold after inject + heal."

| # | Invariant | How to check |
|---|---|---|
| **I1 — No oversell** | seats for a trip are **never negative**; total sold ≤ capacity | `GET /api/inventory/items/{tripCode}` stays ≥ 0; `SELECT status,count(*) FROM reservations GROUP BY 1` reconciles |
| **I2 — No double-charge** | **≤ 1** authorization per order; captured at most once | `GET /api/payments/authorizations/{orderId}` returns 0 or 1; `UNIQUE(order_id)` holds |
| **I3 — Bounded termination** | every order reaches a **terminal** state (`CONFIRMED`/`REJECTED`) within the sweeper deadline (post-pay) or the checkout window (pre-pay) after the fault heals | `SELECT status,count(*) FROM orders GROUP BY 1` — the non-terminal pile (HELD/PAYING/AUTHORIZED) drains to ~0 |
| **I4 — Intake availability** | `POST /api/orders` returns **202** whenever ≥1 orchestrator replica is up | curl intake during the fault |
| **I5 — No committed work lost** | a committed order / reservation / payment survives any pod/broker/DB bounce (outbox is durable) | outbox backlog (`published_at IS NULL`) drains after heal; no gap in aggregate history |
| **I6 — Graceful degradation** | a **non-money** dependency being fully down (Notifications, Catalog) never blocks the saga | orders still reach `CONFIRMED` while that service has 0 replicas |

---

## 2. The matrix

Legend: **kind** = reproducible locally · **AKS** = graded infra proof, AKS-only. "Runbook §" points to the
worked drill in `kind-failure-drills.md`; rows with no § are detailed in [§3](#3-experiment-details-new-rows).

### A. Pod availability — "turn a pod off"

| ID | Experiment | Inject | Invariants at risk | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|--------------------|--------------------|----------------|-------|---------|
| **P1** | Payments **offline** | `kubectl -n eurotransit scale deploy/payments --replicas=0` | I2, I3 | a paid booking's `authorize-payment` buffers in Kafka; orders stall at `PAYING`; within the checkout window the **timeout sweeper** re-drives (recover); past the window the **expiry sweeper** rejects `SERVICE_UNAVAILABLE` (give up) | short outage → on `--replicas=2` backlog drains, orders → `CONFIRMED`, **exactly one** auth per order; outage > window → `REJECTED(SERVICE_UNAVAILABLE)`, hold voided (tombstone), **no charge** | kind | Drill 1 |
| **P2** | Inventory **offline** | `kubectl -n eurotransit scale deploy/inventory --replicas=0` | I1, I3 | `reserve-seats`/`confirm-seats` buffer; pre-pay legs stay `PENDING` (order `HELD`), post-pay orders stall at `AUTHORIZED` (sweeper re-drives) | heal within the window → orders converge, seats never negative, one hold per order; heal past the window → `REJECTED(EXPIRED_NO_PAYMENT)` | kind | — |
| **P3** | **Orchestrator** offline (Orders) | scale **both** `deploy/orders` **and** `deploy/orders-canary` to 0 | I3, I4, I5 | intake 503 at ingress (fail-fast, no data loss); replies buffer on reply topics; **sweeper is paused** (only Orders runs it) | on restore: unpublished outbox rows relay, buffered replies consume, sagas resume to terminal — nothing lost | kind | — |
| **P4** | **Notifications** offline | `kubectl -n eurotransit scale deploy/notifications --replicas=0` | **I6** | Notifications is a terminal *observer*; its listener failures never propagate; it has no PDB (allowed fully down) | orders still reach `CONFIRMED`/`REJECTED` with Notifications at 0 replicas — saga unaffected | kind | — |
| **P5** | **Catalog** offline | `kubectl -n eurotransit scale deploy/catalog --replicas=0` | I6 | Catalog is read-only, **not in the saga**; only browse 503s | in-flight + new orders still terminate; only `GET /api/catalog/*` degrades | kind | — |
| **P6** | Pod-kill **mid-flight** (Inventory) | `kubectl -n eurotransit delete pod -l app.kubernetes.io/name=inventory` | I1 | at-least-once redelivery of in-flight `reserve-seats`; atomic conditional `UPDATE` + `UNIQUE(order_id,trip_code)` + `@Version` | seats stay ≥ 0 throughout; redelivery is an idempotent replay, never a 2nd hold | kind | Drill 3 |
| **P7** | **Rolling update** (Orders) | `kubectl -n eurotransit rollout restart deploy/orders` | I3, I4, I5 | preStop drain + cooperative `scope.cancel()`; PDB `minAvailable:1` keeps a replica serving; new pod resumes relay + sweeper | 202 throughout; no saga step lost or double-applied | kind | Drill 4 |
| **P8** | **Both replicas** of a participant killed at once | `kubectl -n eurotransit delete pod -l app.kubernetes.io/name=payments` | I2, I3 | consumer group momentarily 0 members; offsets not committed for in-flight → redelivered on restart | on restart: single outcome per order; group re-joins; lag → 0 | kind | — (extends Drill 3) |

### B. Network — "pod is up but can't talk"

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **N1** | Payments ↔ Kafka **partition** | `NetworkChaos` (adapt `platform/chaos-mesh/04-kafka-partition.yaml` selector to `payments`) | I3 | same stall as P1 **but pod stays `Ready`** — liveness is process-only, excludes Kafka | no restart storm; consumption + convergence resume on heal | kind | Drill 2 |
| **N2** | Orders ↔ Kafka **partition** | `kubectl apply -f platform/chaos-mesh/04-kafka-partition.yaml` (~3m, auto-reverts) | I4, I5 | intake still 202 (order+outbox commit locally); `outbox drain failed, will retry` streams; backlog grows | drains **in creation order** on heal; nothing lost/duplicated | kind | Drill 5 |
| **N3** | Service ↔ **own DB** partition | `NetworkChaos` between a service and its `*-db-rw` Service | I3, I5 | writes fail → transaction rolls back → command retried/DLT'd; readiness flips pod out of endpoints | on heal: no partial writes; idempotent re-drive completes the step | kind | — |

### C. CDC relay (Debezium) — "outbox drainer down, broker healthy"

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **C1** | Debezium Connect **offline** | `kubectl -n kafka patch kafkaconnect debezium-connect --type=merge -p '{"spec":{"replicas":0}}'` | I3, I5 | outbox rows commit but never publish → **backlog grows in every service DB** though the broker is fine; distinct from K1 | on restore (`replicas:1`): CDC resumes from its offset, backlog drains, sagas converge — no loss, no dup | kind | — |

### D. Broker / Kafka

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **K1** | Kafka **partition** (buffering) | `platform/chaos-mesh/04-kafka-partition.yaml` | I5 | outbox buffers; consumers lag; heal → drain | convergence, nothing lost/duplicated | kind | Drill 5 |
| **K2** | **Broker kill** / failover | delete the broker pod | I3, I5 | kind: single broker → **hard outage, no failover** (prove buffering via K1 instead). AKS: `RF=3`,`minISR=2` → survive 1 broker loss with no data loss | AKS: producers/consumers continue; no `min.insync` stall beyond election | AKS | Drill 5 (caveat) |
| **K3** | **DLT** — poison / exhausted message | produce a malformed record to a command topic, or force 3 consecutive handler failures | I3 | bounded retry (3 × 500ms) → `DeadLetterPublishingRecoverer` → `*-dlt`; **partition unblocked** (no head-of-line block) | poison lands in `<svc>-dlt`, healthy traffic keeps flowing; **blind spot: not app-logged** — watch `*-dlt` counts in Kafka UI | kind | — (see runbook §3 #1) |

### E. Database (CNPG) — postures differ per service *by design*

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **D1** | `orders-db` pod loss | `kubectl -n eurotransit delete pod orders-db-1` | I3, I5 | 2 instances → CNPG promotes standby; brief write stall as transient errors; readiness flips. Async repl → **RPO>0** possible, covered by idempotent re-drive | no committed order lost; saga re-drive covers any interrupted step | kind (subset) / AKS (RTO) | Drill 6 |
| **D2** | `inventory-db` **primary isolated from both standbys** | `NetworkChaos` isolating the primary | **I1** | synchronous repl + `dataDurability=required` → **writes BLOCK** (PC/EC: consistency over availability). `reserve-seats` can't commit → legs stay `PENDING` (order `HELD`) | on heal: **RPO=0**, no reservation lost, **no oversell** even across failover | AKS | — |
| **D3** | `payments-db` pod loss | `kubectl -n eurotransit delete pod payments-db-1` | I2 | single instance (no HA) → write stall until CNPG restarts the pod; correctness = `UNIQUE(order_id)` idempotency table on the PVC, not replication | on restart: still ≤1 auth per order; no double-charge | kind | — |
| **D4** | Node / AZ loss + failover **RTO/RPO** | drain/cordon a node (AKS) | I3, I5 | CNPG failover; measure against `docs/slo.md` (RTO ≤ 60s) | RTO ≤ 60s; inventory RPO=0, orders RPO bounded | AKS | `docs/chaos/05-pg-failover.md` |

### F. External dependency

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **X1** | **PSP** (PayPal) 5xx / timeout | point Payments at a bad `PAYPAL_BASE_URL`, or a latency/abort `NetworkChaos` to the PSP; or a fake gateway throwing `TransientPspException` | I2, I3 | Payments-local `@Retry(paypal)` 3×0.5s + `@CircuitBreaker(paypal)`; exhausted → `TransientPspException` → tx rollback → Kafka retry/DLT + sweeper re-drive. (This is the **PSP-facing** breaker inside Payments — *not* the retired saga breaker.) | no charge on transient failure; on PSP recovery, order captures exactly once | kind (fake/latency) / cluster (real sandbox) | — |
| **X2** | PSP **declines** (business outcome) | order amount ≥ `PAYMENTS_DECLINE_THRESHOLD_CENTS` (mock) | I1, I2 | *Not infra chaos* — the `DECLINED` branch: `release-seats` compensation → `REJECTED(PAYMENT_DECLINED)` | seats restocked, no charge, order rejected — best tested at component tier (`OrderSagaTest`) | kind | — |
| **X3** | **Keycloak** offline | `kubectl -n eurotransit scale statefulset/keycloak --replicas=0` | I3 (not I4) | **auth-plane vs data-plane isolation**: new intake 401s (no token), but in-flight sagas + the async pipeline (already-authenticated work) are untouched | in-flight orders still reach terminal; only *new* logins/intake blocked | kind | — |

### G. Load & time

| ID | Experiment | Inject | Invariants | Expected mechanism | Pass criterion | Where | Runbook |
|----|-----------|--------|-----------|--------------------|----------------|-------|---------|
| **L1** | Intake **load spike** | `just loadtest` with high `K6_VUS` | I2, I3 | Resilience4j `@RateLimiter(orders-intake)` sheds at 20 req/s → **HTTP 429 + Retry-After**; accepted orders still exactly-once | 429s appear, no crash, accepted orders terminate correctly; no double effects | kind | — |
| **T1** | **Clock skew** on Orders pod | Chaos Mesh `TimeChaos` on the orders pod | I3 | sweeper deadline (`PT2M`) & reservation TTL (`PT2M`) are duration-based; a skewed clock can cause premature/late re-drive — validates re-drive stays idempotent regardless | no duplicate effects even under early re-drive; orders still converge | kind (advanced) | — |

---

## 3. Experiment details (new rows)

Only the rows **not** already worked in `kind-failure-drills.md`. Format: **Inject → Observe → Expect → Rollback.**
Run **one at a time under steady load** (`just loadtest`) so any effect has a single cause.

### P3 — Orchestrator offline (Orders)
The "what if the conductor itself dies" test. Orders is the only service that runs the outbox relay for its own
commands **and** the `OrderTimeoutSweeper`.
- **Inject:** `kubectl -n eurotransit scale deploy/orders --replicas=0 && kubectl -n eurotransit scale deploy/orders-canary --replicas=0` (both, because `orders-weighted` splits ingress across the stable + canary deployments — leaving canary up would keep serving intake).
- **Observe:** `POST /api/orders` now fails fast at the ingress (503/no endpoints) — this is **expected**, not a violation of I4 (no orchestrator is up). Replies from Payments/Inventory pile up on `reservation-result` / `payment-result` / `seats-confirmed` / `payment-captured` (Kafka UI: growing lag, 0 consumer members for the orders groups). No sweeping happens.
- **Expect:** on `--replicas=2`, unpublished `outbox_events` rows relay in creation order, the buffered replies are consumed, and every in-flight saga resumes to a terminal state. **I5 holds** because the outbox is the durable source of truth — nothing was in flight-only memory.
- **Rollback:** `kubectl -n eurotransit scale deploy/orders --replicas=2` (canary back to its floor, `--replicas=1`).

### P4 — Notifications offline (graceful degradation, I6)
The headline "a non-critical dependency is allowed to be fully down" proof. Notifications is `replicaCount:1`,
**no HPA, no PDB** — deliberately disposable.
- **Inject:** `kubectl -n eurotransit scale deploy/notifications --replicas=0`.
- **Observe:** `notification-requested` backlog grows in Kafka UI; **no orders stall**. `SELECT status,count(*) FROM orders` keeps flowing to `CONFIRMED`/`REJECTED`.
- **Expect:** the saga terminal step emits `notification-requested` fire-and-forget; Orders never awaits it. **I6 holds.** On restore, buffered notifications are consumed (idempotently — see `NotificationsListenerTest`).
- **Rollback:** `kubectl -n eurotransit scale deploy/notifications --replicas=1`.

### P5 — Catalog offline
- **Inject:** `kubectl -n eurotransit scale deploy/catalog --replicas=0`.
- **Observe:** `GET /api/catalog/*` → 503; the saga is untouched (Catalog is read-only, not a participant).
- **Expect:** in-flight and new orders still terminate. Only browse degrades. **I6 holds.**
- **Rollback:** `kubectl -n eurotransit scale deploy/catalog --replicas=2`.

### C1 — Debezium Connect offline (CDC relay down, broker healthy)
Distinct from a Kafka outage (K1/N2): here the **broker is fine**, but the thing that drains the outbox onto
topics is gone. Proves the outbox is durable and the relay is resumable.
- **Inject:** `kubectl -n kafka patch kafkaconnect debezium-connect --type=merge -p '{"spec":{"replicas":0}}'`. (Deleting only the pod tests transient loss — Strimzi recreates it.)
- **Observe:** business writes still commit (intake 202, reservations/auths recorded), but **`SELECT count(*) FROM outbox_events WHERE published_at IS NULL` climbs in every service DB** and Kafka command/reply topics go quiet. Sagas freeze mid-flight.
- **Expect:** on `replicas:1`, Debezium resumes from its stored offset, republishes the backlog **in order**, consumers catch up, sagas converge. No loss, no duplication (idempotent consumers). **I5 holds.**
- **Rollback:** `kubectl -n kafka patch kafkaconnect debezium-connect --type=merge -p '{"spec":{"replicas":1}}'`.

### K3 — DLT: poison / exhausted message
- **Inject:** simplest is to force 3 consecutive handler failures (e.g. temporarily point a service at a broken dependency while a command is redelivered), or produce a deliberately malformed record to a command topic via Kafka UI.
- **Observe:** after 3 retries (500ms backoff) the record appears in `inventory-dlt` / `payments-dlt` / `orders-dlt`. Healthy traffic on the same partition keeps flowing (no head-of-line blocking).
- **Expect:** the poison is parked, offset advances, the saga for that order stalls (it never got its reply) and is a candidate for the sweeper / manual DLT replay.
- **Blind spot:** DLT routing is **not logged at the app layer** (runbook §3 #1) — you only see it as a non-zero `*-dlt` count in Kafka UI; consume the record to read the exception from its headers.
- **Rollback:** none (drain/replay the DLT manually if you want the order to complete).

### D2 — inventory-db primary isolated from both standbys (AKS)
The invariant-store consistency proof. `inventory-db` is **3 instances, synchronous replication,
`dataDurability=required`** — chosen precisely so a failover can never lose a committed reservation (RPO=0),
even though that means writes **block** under a full partition (PACELC PC/EC — consistency over availability).
- **Inject (AKS):** `NetworkChaos` isolating the primary from both standbys (or drain its node).
- **Observe:** `reserve-seats`/`confirm-seats` handlers block on commit → legs stay `PENDING` (order `HELD`) / order stalls at `AUTHORIZED`; intake still 201/202 (orders-db unaffected).
- **Expect:** **no oversell (I1)** and **no lost reservation (I5)** across the failover; on heal, blocked writes complete or roll back cleanly and the sweeper re-drives. RPO=0.
- **kind caveat:** single-node/single-instance on kind — you can only kill the pod (D3-style) to see transient handling; the write-block / RPO=0 proof is **AKS-only**.

### D3 — payments-db pod loss
- **Inject:** `kubectl -n eurotransit delete pod payments-db-1`.
- **Observe:** brief write stall in Payments (transient errors, readiness flips); CNPG restarts the single instance.
- **Expect:** because there is **no standby**, writes pause until the pod is back — but **no double-charge (I2)**: the `UNIQUE(order_id)` idempotency row is committed data on the PVC, so any redelivered `authorize-payment` after recovery replays the stored outcome.
- **Rollback:** CNPG self-heals the pod.

### X1 — PSP (PayPal) transient failure
- **Inject (kind, no real PSP):** set `PAYMENTS_PROVIDER=paypal` with a bad `PAYPAL_BASE_URL`, or apply a latency/abort `NetworkChaos` toward the PSP egress, or wire a fake `PaymentGateway` bean that throws `TransientPspException`.
- **Observe:** Payments logs retry attempts; after 3 the circuit for `paypal` may open; `authorize-payment` throws → tx rolls back → Kafka retry, then DLT if it keeps failing; the sweeper re-drives the stalled order.
- **Expect:** **no charge on a transient failure (I2)**; when the PSP recovers, the re-driven `authorize-payment` succeeds and the order captures exactly once. Note this breaker is **inside Payments, facing the PSP** — the old saga-level breaker is retired.
- **Rollback:** restore `PAYPAL_BASE_URL` / delete the NetworkChaos / redeploy with the mock gateway.

### X3 — Keycloak offline
- **Inject:** `kubectl -n eurotransit scale statefulset/keycloak --replicas=0` (Keycloak is a StatefulSet via the operator).
- **Observe:** `POST /api/orders` with a new login fails (401 — no token / JWKS unreachable). But orders already in flight keep advancing through the Kafka pipeline.
- **Expect:** **auth-plane vs data-plane isolation** — data-plane work in flight is unaffected; only *new* authenticated intake is blocked. This is why the money path doesn't call Keycloak per-message (it validates JWT signatures against cached JWKS).
- **Rollback:** `kubectl -n eurotransit scale statefulset/keycloak --replicas=1`.

---

## 4. Results log (fill in per run)

Chaos engineering is only done when the hypothesis is confirmed *or* refuted against a real run. Record each
execution so the capstone has evidence, not just intent.

| Date | ID | Cluster | Injected | Steady state held? (I#) | Observed recovery time | Notes / surprises |
|------|----|---------|----------|-------------------------|------------------------|-------------------|
| | P1 | kind | payments→0 | I2,I3 ✅? | | |
| | P3 | kind | orders→0 | I3,I5 ✅? | | |
| | P4 | kind | notifications→0 | I6 ✅? | | |
| | C1 | kind | debezium→0 | I5 ✅? | | |
| | D2 | AKS | inv-db partition | I1 ✅? | | |
| | … | | | | | |

> A refuted hypothesis (invariant broken) is a **finding**, not a failure of the exercise — log it, link the
> fix, re-run to green.
