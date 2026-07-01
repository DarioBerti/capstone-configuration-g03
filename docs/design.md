# EuroTransit — Design & consistency justification (g03)

> Team-owned. The agent helped draft and explain; every decision below is one we can defend
> at the oral. This is the canonical design doc; the shared team document mirrors it.

## 1. Architecture

```mermaid
flowchart TB
    Client([Client / Load-gen]) -->|HTTPS| Traefik[Traefik Ingress + TLS]
    Traefik -->|sync GET| Catalog[Catalog svc]
    Traefik -->|sync POST /api/orders → 202| Orders[Orders svc]
    Catalog --> CatDB[(Catalog DB)]
    Orders --> OrdDB[(Orders DB + outbox)]
    Inventory --> InvDB[(Inventory DB atomic UPDATE + outbox)]
    Payments --> PayDB[(Payments idempotency + outbox)]
    Orders -.->|commands: reserve-seats / authorize-payment / confirm-seats / capture-payment| Kafka{{Kafka / Strimzi}}
    Kafka -.->|commands| Inventory[Inventory svc]
    Kafka -.->|commands| Payments[Payments svc]
    Inventory -.->|replies: reservation-result / seats-confirmed| Kafka
    Payments -.->|replies: payment-result / payment-captured| Kafka
    Kafka -.->|replies| Orders
    Kafka -->|notification-requested / order-confirmed| Notifications[Notifications svc]
    Notifications -.->|may fail without failing checkout| Sink([Email/SMS mock])
    Orders -.->|order-placed (self) / -confirmed / -rejected| Kafka
```

The money path is **fully asynchronous**: there is no synchronous Orders→Inventory/Payments call. Orders
orchestrates by emitting **commands** and reacting to **replies**, each carried on its own Kafka topic and
each service replying from its **own transactional outbox** (replies are load-bearing, not best-effort).
See decision 13 (async saga cutover) for the rationale and the Pillar A↔C trade-off.

## 2. Money path (critical path)

Orchestrated, **serial, two-phase (hold → commit), capture-last** async saga. Orders owns the state
machine `PENDING → RESERVED → AUTHORIZED → CONFIRMED` (`REJECTED` terminal); every command/reply commits
together with the state change via the transactional outbox, and every handler is idempotent (status guard
+ `UNIQUE(order_id…)`).

1. **Place order (sync, returns fast):** `POST /api/orders` → Orders persists the order `PENDING` and
   writes `order-placed` to the **outbox** in the *same* DB transaction; returns **202 Accepted**.
2. **Trigger (outbox → Kafka → self):** the relay publishes `order-placed`; Orders consumes it and emits
   the `reserve-seats` command (at-least-once).
3. **Phase 1 — hold the seat.** Inventory consumes `reserve-seats`, does the atomic conditional UPDATE,
   and replies `reservation-result` from its outbox: `RESERVED` → Orders advances to `RESERVED` and emits
   `authorize-payment`; `SOLD_OUT` → Orders `REJECTED` (nothing held).
4. **Phase 1 — hold the funds.** Payments consumes `authorize-payment`, **authorizes only (holds funds, no
   capture)**, and replies `payment-result`: `AUTHORIZED` → Orders advances to `AUTHORIZED` and emits
   `confirm-seats`; `DECLINED` → Orders emits `release-seats` (compensation) and `REJECTED`.
5. **Phase 2 — commit the seat.** Inventory consumes `confirm-seats`, commits the hold, and replies
   `seats-confirmed`: `CONFIRMED` → Orders emits `capture-payment`; `EXPIRED` (hold lapsed under payment
   lag) → Orders emits `cancel-authorization` (releases the funds hold — **no capture, so no refund**) and
   `REJECTED`.
6. **Phase 2 — capture the funds (capture-last).** Payments consumes `capture-payment`, captures the held
   funds, and replies `payment-captured` → Orders → `CONFIRMED`, emits `order-confirmed` +
   `notification-requested`.
7. **Notify (fully async, degrades):** Notifications consumes `notification-requested`; if down, checkout
   has already succeeded.

**Key property:** money is *captured last*, only after the seat hold is committed — so there is never a
captured charge without a confirmed seat, and a hold that expired under payment lag is caught at
`confirm-seats` (and the free authorization-cancel runs) rather than silently oversold or charged. A reply
that never arrives is re-driven by the **timeout sweeper** (re-drive is safe — commands are idempotent); a
poison/exhausted message is parked on the consumer's dead-letter topic (`*-dlt`).

## 3. Sync vs async boundaries

| Boundary | Mode | Why |
|---|---|---|
| client → gateway → Catalog | sync | read, tolerant of staleness |
| client → gateway → Orders (place) | sync, returns 202 | user needs an immediate ack, not the full result |
| Orders ↔ Inventory (reserve / confirm / release) | **async** Kafka command/reply | decouple the money path; absorb bursts as lag, ride a downstream outage |
| Orders ↔ Payments (authorize / capture / cancel) | **async** Kafka command/reply | as above; capture-last keeps money safe across the gap |
| pipeline stages / all eventing | async (Kafka) | decouple, absorb bursts, survive downstream blips |
| Notifications | async | must fail without failing checkout |

> Updated by decision 13 (async cutover, 2026-06-30): the former synchronous Orders→Inventory/Payments
> HTTP calls ("a decision must be made now") are now Kafka commands answered by replies. The decision is
> still made before the saga advances — it just travels over the log instead of an open HTTP connection.

## 4. Design decisions (summary — full rationale owned by team)

1. **Database-per-service** (ownership, not just SPOF). Orders (2 instances) and Inventory
   (3 instances) are the HA, correctness-critical stores. Payments gets a small **dedicated
   single-instance** cluster *(team decision, 2026-06-09)*: it is on the money path but not
   contended — "no double-charge" is enforced by the idempotency table regardless of
   availability, and unavailability is contained by the Orders circuit breaker + fallback.
   Kept as a dedicated Cluster CR (not a logical DB inside another cluster) because CNPG's
   `initdb` bootstrap + auto-generated `-app` secret work per-cluster; a second database in a
   shared cluster needs Database CRs + managed roles + hand-made secrets and couples failure
   domains. Catalog single (staleness-tolerant). No service reads another's DB.
2. **No dedicated auth service** (not required; would be scope creep). Optional gateway-level
   token/forwardAuth only.
3. **Orchestrated saga** (Orders coordinates; stages Kafka-driven; compensations on failure). *(Refined by
   #13: now serial two-phase hold→commit, capture-last — the state machine is `PENDING → RESERVED →
   AUTHORIZED → CONFIRMED`, and each step is a Kafka command answered by a reply.)*
4. **Transactional outbox** to avoid the dual-write problem → at-least-once → idempotent consumers.
   *(Extended by #13: Inventory and Payments now each own an outbox too — their replies are load-bearing,
   not the old best-effort informational events.)*
5. **Inventory consistency = CP / PACELC PC-EC**: prefer rejecting a reservation over overselling
   in a partition; accept slightly higher latency for consistency without a partition.
   Implemented as an atomic conditional `UPDATE ... WHERE available >= qty` (single-row,
   transactional) + a reservation state machine (`RESERVED → CONFIRMED | RELEASED/EXPIRED`).
6. **Idempotency** on the money path: key = `orderId`. Inventory dedup `(orderId, productId)`;
   Payments dedup by key with persisted result. **Dedup-insert and decrement in one transaction.**
7. **Resilience4j — circuit breaker / retry / bulkhead on Orders→Payments (Phase 2 #1–#4).**
   ⚠️ **SUPERSEDED by decision 13 (async cutover, 2026-06-30).** The money path no longer makes a
   synchronous Orders→Payments HTTP call, so the circuit breaker, the per-dependency bulkheads, the
   inline transport retry, and the `void`/refund compensation described below were **removed** along with
   the `gateway/` package and the `PAYMENT_PENDING` park state. The resilience story they provided is
   replaced by Kafka buffering + bounded consumer retry + dead-letter topics + the timeout sweeper (see
   #13). The text below is retained as the historical record of what was built and why; the **only**
   surviving Resilience4j use is the edge `@RateLimiter` (Phase 2 #3, still current). The circuit breaker
   was a checked Pillar C / DoD item — #13 documents that deliberate Pillar A↔C re-balance.

   Orders→Payments **was** wrapped in a circuit breaker applied **programmatically** through the injected `CircuitBreakerRegistry`
   (`HttpPaymentsGateway`), **not** the `@CircuitBreaker` annotation. Annotations now weave on Boot 4
   (resilience4j 2.4.0 / `resilience4j-spring-boot4`, agent-log #2), so the registry is a **deliberate
   design choice, not a compatibility workaround**: the gateway composes `Retry(CircuitBreaker(Bulkhead(…)))`
   in one explicit, reviewable order, the decoration is immune to AOP self-invocation gaps, and it is
   deterministically testable without a proxied context (proven end-to-end by `PaymentsGatewayBreakerIntegrationTest`).
   Policy (`instances.payments`): COUNT window 10, min 5 calls, **open at >50% failures OR >50% slow calls
   (slow = >2s)** — the prof's two open criteria (deck 11 s.17); wait-open 10s, 2 half-open probes, auto-transition.
   `ignore-exceptions: HttpClientErrorException` so a 4xx never trips the breaker; a 4xx is instead mapped to a
   terminal DECLINED (a permanent client error must not park forever). A transport fault → fallback `"UNAVAILABLE"`
   → the saga PARKS the order in **`PAYMENT_PENDING`** (it does not reject — the card may be fine — and does not
   propagate). `OrderRecoverySweeper` retries parked orders and **bounds the park by age** (`app.recovery.max-park`
   ≤ inventory hold TTL), rejecting a clearly-expired hold WITHOUT re-authorizing so a card is never charged for a
   restocked hold (since #4 the sweep also voids any live charge before rejecting, and on an unreachable Payments keeps
   the order parked to retry the void rather than abandon it — see decision 7 #4; observable via
   `orders_recovery_total{outcome=void_retry}` / `orders_compensations_total{type=refund}`). The breaker is excluded
   from health (`management.health.circuitbreakers.enabled: false`) — an OPEN breaker is the system working, not
   failing. An **optimistic lock** (`@Version` on `Order` + migration V2) prevents duplicate terminal outbox events
   when the sweep races across pods (the loser rolls back). The thresholds are a team policy decision.

   **Resilience4j — retry + bulkhead + timeout (Phase 2 #2, IMPLEMENTED 2026-06-26).** Both gateways now route every
   remote call through `GatewayResilience` (single source of truth for the policy composition), applied
   **programmatically** like #1 (per-module `Bulkhead`/`CircuitBreaker`/`Retry.decorateCallable`, **not** the
   `@Bulkhead`/`@Retry` annotations — and not the `Decorators` builder, which lives in `resilience4j-all`, a
   non-dependency; the per-module decorators are already on the starter's classpath). **Composition order** =
   `Retry( CircuitBreaker( Bulkhead( call ) ) )` (canonical R4j, retry outermost). **Retry**
   (`instances.{payments,inventory}`): max-attempts 3, 200ms base, exponential ×2 + jitter; `retry-exceptions` =
   **transport only** (`HttpServerErrorException`, `ResourceAccessException`) — never a 4xx / business outcome, never
   `CallNotPermittedException` (breaker OPEN ⇒ fast-fail, no retry storm, slide 45) or `BulkheadFullException`. The
   values are **deliberately shorter than the slide-22 example (1s/2s/4s, cap 30s, max 5)**: the slide's own rule is
   "derive retry/timeout from the end-to-end deadline", and our checkout SLO is e2e p95 ≤ 5s — so the inline retry only
   absorbs up to two transient blips (max-attempts 3 = 1 call + 2 retries), while a sustained outage is handled by breaker → `PAYMENT_PENDING` → recovery sweep
   (the "long retry"). **Bulkhead** (SEMAPHORE, fail-fast `max-wait 0` — no queue, slide 7): separate instances
   `payments` (8) / `inventory` (16) — the separation IS the isolation (a slow Payments exhausts only its own permits,
   deck 11 s.20); a saturated Payments bulkhead → `BulkheadFullException` → mapped to `UNAVAILABLE`/park (controlled
   refusal, observable as `orders_payment_failures_total{outcome=bulkhead_full}` — a DISTINCT outcome from a
   downstream-down/breaker-open `unavailable`), and added to the **breaker's ignore-exceptions** so a local concurrency
   cap never by itself opens the breaker (genuine slowness is already caught by the >2s slow-call rate). **Timeouts** (connect 2s / read 5s,
   unchanged) are the per-call deadline partition of the checkout budget — there is no `docs/slo.md` file yet, so the
   budget is documented here. The breaker stays **Payments-only** (Inventory is the contended resource, not a money
   coordinator; bulkhead + idempotent retry suffice). Proven by `RetryBulkheadConfigTest` (non-default binding +
   retry-exceptions whitelist), `PaymentsRetryTest` (5xx retried, 4xx not), `BulkheadIsolationTest` (saturate Payments
   ⇒ Inventory unaffected), `PaymentsRetryIntegrationTest` (503→503→200 absorbed end-to-end; always-503 → UNAVAILABLE).
   Sizes/attempts are a team policy decision, tunable.

   **Resilience4j — backpressure / load shedding (Phase 2 #3, IMPLEMENTED 2026-06-26).** The synchronous intake
   `POST /api/orders` is rate-limited: over budget it is refused immediately with **HTTP 429 + `Retry-After`**
   instead of being queued ("backpressure is controlled refusal"; "queues just delay the failure", deck 11 s.24/7).
   Applied via the **`@RateLimiter(name="orders-intake")` annotation** on `OrdersController.place()` (resilience4j
   2.4.0 / `resilience4j-spring-boot4` + `spring-boot-starter-aop`): over budget the aspect throws
   `RequestNotPermitted` **before** the handler body runs (DB/outbox untouched), and `GlobalExceptionHandler`
   maps it to 429 + `Retry-After` and counts the shed. Unlike the gateway (#1/#2), there is no composition to
   order and no self-invocation path, so the annotation is the simpler fit here. `instances.orders-intake`:
   `limit-for-period 20`, `limit-refresh-period PT1S`, `timeout-duration PT0S` (never queue — shed at once). The
   `Retry-After` value is **derived from the limiter window** (not a magic number). Health indicator disabled
   (`management.health.ratelimiters.enabled: false`) like the breaker — shedding is the system *working*, it must
   not flip readiness. The 429 lives **only at the edge**; internal saga calls are governed by breaker/bulkhead,
   never a 429 (#3.5). Observable as the low-cardinality counter `orders_intake_shed_total`. Proven by
   `OrdersIntakeRateLimiterTest` (within budget → 202; over budget → shed counted → 429 + Retry-After). The
   threshold is a team policy decision, tunable from a load-test baseline.

   **Resilience4j — refund/void compensation (Phase 2 #4, IMPLEMENTED 2026-06-26).** Closes the saga's last gap:
   if the inventory hold expires AFTER `authorize` charged the card, the saga now **voids** the charge before
   rejecting, preserving the invariant *"no charge without a seat"* (decision #3). **Void = an idempotent state
   transition `AUTHORIZED → VOIDED` on the EXISTING `payment_authorizations` aggregate** (`PaymentsService.void`,
   `POST /api/payments/authorizations/{orderId}/void`) — **not** a separate reversal table: it is the real PSP
   semantics (cancel an un-captured authorization), and re-voiding a `VOIDED` row is a replay. *"refund" in the
   metric name denotes this void primitive* (the mock PSP authorizes, never captures, so there is no CAPTURED
   state to refund). **No migration**: `VOIDED` writes into the existing `status VARCHAR(16)` with no CHECK; on
   postgres `ddl-auto: validate` checks the column mapping, not the enum value-set. **No Kafka event** (payment
   events are best-effort/informational with no consumer). The gateway `payments.void` reuses the **same `payments`
   Resilience4j instance** as authorize (breaker+bulkhead+retry — same downstream, idempotent ⇒ retry-safe, slide
   22), with the **same 4-branch fallback** (distinct `bulkhead_full` vs `unavailable`; a void 404 → benign
   `NOT_FOUND`). **Failed-void handling = Option B (team decision):** on `UNAVAILABLE`/`FAILED` the saga does **not**
   go terminal with a live charge — it **parks** (`PAYMENT_PENDING`) so `OrderRecoverySweeper` re-drives the saga and
   **retries the void** until it succeeds. At the `app.recovery.max-park` boundary the sweep is consistent with this:
   it voids, then rejects only when the money state is **resolved** (`VOIDED` = reversed, or `NOT_FOUND`/`DECLINED` =
   no charge ever); if Payments is still unreachable (`UNAVAILABLE`/`FAILED`) it **keeps the order parked and retries
   the void next sweep** rather than abandoning a possibly-live charge (`orders_recovery_total{outcome=void_retry}`).
   *Tradeoff (team decision):* this trades the old bounded-retention guarantee for money-safety — during a sustained
   Payments outage parked orders drain on recovery instead of being force-terminated at max-park. A crash between
   void and reject is absorbed by a `"VOIDED" → reject(RESERVATION_EXPIRED)` branch in the stage-2 dispatch (a
   VOIDED replay = already compensated). Observable via `orders_compensations_total{type="refund"}` (successful
   reversals, counted once via the `replayed` flag) and `payments_voids_total{outcome}`. **Follow-up:** a lost-update guard (`@Version` / conditional
   `UPDATE … WHERE status='AUTHORIZED'`) on the void transition is **deferred** — money-safe today (void has no
   external side-effect, so a concurrent double-void converges to the same `VOIDED` row), and adding `@Version`
   would break the migration-free property; it becomes required only if a real PSP storno side-effect is ever added.
   Proven by `OrderSagaTest` (compensation #5.4, failed-void-parks-then-rejects, VOIDED-replay) and
   `PaymentsServiceTest` (void idempotency, no-op on declined, not-found). The design's first cut (reject-always +
   counter) only OBSERVED the leak; a 3-lens adversarial review caught it — see `agent-log.md` #9.
8. **Tracing:** OpenTelemetry via Micrometer Tracing → OTLP → Tempo/Jaeger; propagate context
   across Kafka headers.
9. **Progressive delivery:** canary via Traefik `TraefikService` (weighted); blue/green via dual
   deployments + routing switch. all-at-once/rolling discussed but not used on the critical path.
10. **No heavyweight frontend:** a thin client / load generator (k6) is enough to demonstrate
    behaviour under load.
11. **Observability decisions** *(team, 2026-06-10)*: **Tempo** as tracing backend
    (Grafana-native, exemplars) behind an **OpenTelemetry Collector** gateway; Micrometer →
    Prometheus via ServiceMonitor/PodMonitor; dashboards = money-path overview, per-service
    RED, infra USE, **Kafka consumer lag** (leading indicator of pipeline latency), CNPG.
    SLIs: ack latency measured at the edge (Traefik) + Orders; end-to-end confirm latency and
    success-rate as **business metrics emitted by Orders** (only it sees the state machine —
    not derivable from HTTP metrics because the flow crosses Kafka). Only multi-window
    burn-rate alerts page. Structured JSON logs with traceId; no mandatory log aggregation
    (Loki = bonus). 100% sampling + exemplars at demo scale. Dashboards provisioned as code
    from this repo. Details: `slo.md` + `platform/observability/README.md`.
12. **Replication posture per database (PACELC made concrete)**: CNPG replicates
    asynchronously by default → a failover can lose the last committed transactions (RPO > 0),
    which would break "never oversell" exactly under chaos #5 (a committed reservation
    vanishes, the counter rolls back, the seat is sold twice — the atomic UPDATE protects
    against concurrency, not against losing committed state). Therefore: **inventory-db =
    synchronous replication** (3 instances, ANY 1, `dataDurability: required`) → RPO=0 always;
    one replica can die without blocking writes; if the primary is partitioned from both
    standbys, writes **block** — consistency over availability, exactly our PC/EC statement.
    **orders-db = synchronous `preferred`** (2 instances) → RPO=0 while healthy, degrades to
    async instead of blocking order intake if the standby disappears (the invariants do not
    live in orders-db). payments-db and catalog-db: single instance (see decision 1).
    Requires CNPG ≥ 1.25.

13. **Async saga cutover — sync HTTP → Kafka command/reply (team decision, 2026-06-30).** The money path
    was converted from a synchronous-HTTP orchestration (Orders calling Inventory/Payments over `RestClient`)
    to an **orchestrated, serial, two-phase async Kafka command/reply** pipeline. Analysed in
    `capstone-application-g03/docs/sync-vs-async-resilience.md` (sync-vs-async pros/cons, resilience-pattern
    placement, chaos behaviour); the failure-mode map and the Pillar A scaling analysis drove the choice.
    - **What changed.** Orders emits six commands (`reserve-seats`, `authorize-payment`, `confirm-seats`,
      `capture-payment`, `release-seats`, `cancel-authorization`) via its outbox and reacts to four replies
      (`reservation-result`, `payment-result`, `seats-confirmed`, `payment-captured`); Inventory and Payments
      each gained inbound command listeners and an **outbox of their own** for the (now load-bearing) replies.
      Payments was split **two-phase**: `authorize` holds funds only, `capture` is a separate last step,
      `cancel-authorization` releases an uncaptured hold. The state machine is `PENDING → RESERVED →
      AUTHORIZED → CONFIRMED` (`PAYMENT_PENDING` removed). The old best-effort informational topics
      (`inventory-reserved`, `inventory-released`, `payment-authorized`) were retired — they had no consumer.
    - **Why.** For a transit-ticketing marketplace whose load is bursty (schedule drops, commuter rush,
      promotions), the async design wins where it hurts most — **spike absorption** (a burst becomes bounded
      Kafka lag, not edge 429s), **downstream-outage riding** (a slow/down Payments grows lag, not blocked
      Orders threads — the saga resumes on recovery), and **tail-latency isolation** between hops. Two-phase
      **capture-last** also closes a real oversell/charge gap (a seat hold can expire under payment lag; it is
      now caught at `confirm-seats` and the free authorization-cancel runs — no captured charge without a
      confirmed seat).
    - **The cost (honest Pillar A↔C re-balance).** This **retires the graded Pillar C circuit breaker**
      (decision 7) and its bulkhead/retry/void compensation. The resilience story moves to **Kafka buffering
      + bounded non-blocking consumer retry + a dead-letter topic per service (`orders-dlt`/`inventory-dlt`/
      `payments-dlt`, `DefaultErrorHandler` + `DeadLetterPublishingRecoverer`) + a timeout sweeper** that
      re-drives a saga stuck in a non-terminal state past a deadline (`OrderTimeoutSweeper`; re-drive is safe
      because commands are idempotent). Kafka becomes **load-bearing for every step**, so it must run the
      durable posture (`acks=all`, `min.insync.replicas≥2`, replication 3, no unclean leader election — the
      3-node `kafka.yaml`, not the single-node kind variant). The edge `@RateLimiter` (Phase 2 #3) and
      Inventory's never-oversell guarantee are unchanged. **Virtual threads (Java 21 + Boot 4) + the already-202
      checkout blunt the classic "blocking doesn't scale" argument**, so async here is bought for *resilience
      under burst*, not raw throughput — a deliberate trade the team owns (see §6).
    - **Tests.** The breaker/bulkhead/retry tests were deleted; new coverage proves listener idempotency under
      duplicate redelivery (one hold / one auth / one capture), each transition emits the right next command,
      the three compensations fire, hold-expires-before-confirm → `EXPIRED` with no capture, and the timeout
      sweeper re-drives. All three services green (Payments 21, Inventory 18, Orders 26).

## 4b. Phase 3 — platform decisions (D-A…D-G; team 2026-06-26, deviations verified on the real cluster 2026-06-28)

Bringing the system onto a real cluster (Azure AKS), reconciled by Argo CD. Labels match `docs/FASE3_*`.

- **D-A — one shared AKS cluster** (`lab_g03_cluster`, RG `lab02_g03_group`, region `spaincentral`); every member
  added as *Cluster Admin*, not one cluster per person — a single cluster keeps more shared student credit for the
  work/demo days instead of burning it in parallel.
- **D-B — `az aks stop` when idle** (deallocate the nodes, do not destroy): the one decision that keeps the project
  inside the budget — running h24 ≈ 8€/day vs cents/day stopped (data persists on disk, restart ~3-5 min).
- **D-C — node pool: 3× `Standard_B2s_v2`** (6 vCPU / 24 GiB). *Deviation from the theoretical 2× `B4ms`*: the
  regional quota is only **6 vCPU** and `B4ms`/`B4s_v2` are unavailable in `spaincentral`, so 3× `B2s_v2` is the
  in-quota fit — covers the ~3.3 vCPU / ~9 GiB of requests with RAM headroom, and 3 nodes are actually better for
  the topology-spread / PDB demos. Caveat (Phase 6): a chaos node-kill leaves 4 vCPU → some pods `Pending`, itself a
  documented finding.
- **D-D — platform installed by hand** (`helm`/`kubectl`, once); **only the `eurotransit` app goes through Argo CD**
  (no app-of-apps — operators are "install once"; the track asks for the *app* Synced & Healthy).
- **D-E — free IP-based TLS**: hostname `<TraefikIP>.sslip.io` + Let's Encrypt HTTP-01, no purchased domain. The
  chart's `global.domain` must be the live Traefik LoadBalancer IP in sslip.io form. ⚠️ **Regression (kind merge,
  PR#1):** base `values.yaml` `global.domain` was reverted to the placeholder `g03.cpo2026.it` (the working
  `158.158.71.17.sslip.io` set in 385a39b was lost). Argo CD renders **base `values.yaml` only**, so until
  `global.domain` is reset to the *current* Traefik external IP the HTTP-01 challenge fails and `eurotransit-tls`
  never issues (blocks §6.3, not §5.4). The `letsencrypt-prod` ClusterIssuer is in `platform/cert-manager/`
  (`clusterissuer.yaml`; kind uses `selfsigned` via `values-kind.yaml`). See agent-log #13.
- **D-F — ACR pull via AKS managed identity** (`az aks update --attach-acr`): no `imagePullSecret` in Git
  (Azure-native, fewer secrets to manage).
- **D-G — registry `labg03clusterregistry.azurecr.io`**. *Deviation*: the plan cited `lab02g03registry`, which **does
  not exist**. `values.yaml` (`global.registry` + the five `image.repository`) uses the real registry; the CI had
  drifted to a third name `etg03registry.azurecr.io` and was **realigned** to `labg03clusterregistry.azurecr.io` so
  build target == pull source (the CI bumps only `image.tag`, never the repo). See agent-log #14.
- **Operator versions pinned** (`platform/README.md`, reproducibility — never `latest`): Strimzi **1.0.0** (API `v1`,
  Kafka 4.1.2), CloudNativePG **1.29.1** (≥1.25 ✔ for synchronous replication); Traefik / cert-manager / Sealed
  Secrets / Argo CD were already bootstrapped on the cluster by the earlier labs.
- **No SealedSecret needed in Phase 3** *(by design, not an omission)*: DB credentials are generated in-cluster by
  CNPG (`<db>-app`), and image pull uses the managed identity (D-F). A SealedSecret returns only if a real
  application secret is introduced (e.g. a real PSP token — the PSP is mocked today).

## 5. Open decisions (awaiting teammate feedback)
- ~~D1 granularity~~ → **resolved 2026-06-09** (team feedback): dedicated HA clusters for
  Orders & Inventory; small dedicated single-instance clusters for Payments and Catalog
  (rationale in #4.1; replication posture in #4.12).
- D2: include a minimal gateway auth check at all?
- D9: stick to TraefikService, or also evaluate Argo Rollouts for canary automation? *(decided in Phase 5; for
  Phase 3 it only adds the Argo Rollouts controller as an extra operator if chosen — does not block the bootstrap.)*
- ~~D12 variant (inventory-db 3 vs 2 instances)~~ → **resolved: stays at 3** (survives one replica loss without
  blocking writes; confirmed in the Phase 3 plan, no chart change).

## 6. Async cost analysis (Pillar A)

The async lecture's frame (deck 06): a **blocking** call parks a whole OS thread while it waits; a
**suspending** call frees the thread to do other work and resumes later. So async pays off exactly where
work is **I/O-/wait-dominated**, and pays nothing (or costs more in complexity) where work is **CPU-bound**.
Mapped onto EuroTransit:

**Where async reduces cost / scaling pressure here**
- **The 202 intake.** `POST /api/orders` commits the order + outbox row and returns immediately; the
  reserve→authorize→confirm latency is taken off the request path. User-facing latency is decoupled from
  downstream latency, so a slow Payments does not hold the caller's connection/thread.
- **Kafka across the whole money path (since #13).** Every saga step is now a command/reply over the log,
  not a synchronous call — so a burst becomes a bounded, replayable backlog drained at a sustainable rate
  (load-leveling), and a slow/down Inventory or Payments shows up as **consumer lag, not blocked Orders
  threads**: Orders keeps accepting and the saga resumes on recovery. This is the temporal decoupling the
  sync design could not give, and it is worth most exactly at peak (deck 11 "queues just delay the failure"
  → we bound them with DLT + the timeout sweeper, and shed at the edge with the 429).
- **The background coroutines** (`OutboxPublisher` relay, `OrderTimeoutSweeper`, `ReservationReconciler`).
  Each is one supervised coroutine that spends almost all its time **suspended in `delay()`**, not a parked
  thread — near-zero footprint for "always-on" polling, and they cancel cooperatively on SIGTERM.

**Where async does NOT help (CPU-/DB-bound — the honest other half)**
- **The contended reservation.** Inventory's bottleneck is the **single hot row** serialised by the Postgres
  row lock, not thread availability. Making the call "more async" adds zero reservation throughput — which is
  exactly why **Inventory has no HPA** (scaling pods can't beat a single-row serialisation point; deck 10
  "scale on saturation, not CPU"). The right lever there is the DB / consistency model, not concurrency.
- **Serialization / JSON / the atomic UPDATE itself** are CPU- and DB-bound; you cannot "suspend" your way
  out of work that has to actually execute.

**Blocking-vs-suspending in our own code (the deliberate consequence).** After #13 the money path no longer
has an outbound HTTP client at all — the cross-service work is Kafka listeners + the outbox relay, and the
only blocking left is **JDBC** (and the relay's bounded Kafka ack wait). We do not pretend that is
non-blocking: the background sweeps (`OrderTimeoutSweeper`, `ReservationReconciler`) and the outbox relay run
on **`Dispatchers.IO`** (the elastic pool sized for blocking I/O), and each spends almost all its time
suspended in `delay()` between ticks — placing blocking work on the IO pool and keeping the loop itself
suspension-cheap is the blocking-vs-suspending guidance from deck 06. **Virtual threads (Java 21 + Boot 4)**
further blunt the cost of the remaining blocking JDBC. Net: async is leverage on the wait-dominated edges
(ack, eventing, the whole inter-service saga, background sweeps); on the genuinely CPU/DB-bound core (the
contended single-row reservation, JSON, the atomic UPDATE) we lean on the data model and the consistency
choice instead — which is why Inventory scales on DB saturation, not pod count.
