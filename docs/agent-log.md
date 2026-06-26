# Agent verification log

> Capstone rule: agentic tools are permitted and encouraged, but the team must **verify** and
> **show where the agent was wrong**. This log records concrete cases where an agent-produced
> artifact was incorrect, unsafe, or subtly wrong, and how we caught and corrected it.
> *Finding the agent's mistakes is the core skill the capstone certifies.*

Format per entry: **what the agent produced → why it was wrong → how we caught it → the fix**.

---

## 1. Helm template syntax leaked into a plain (non-templated) manifest

- **Produced:** `platform/strimzi/kafka-topics.yaml` with a Helm comment
  `{{- /* ... */}}` at the top. These topics are applied directly at platform bootstrap, not
  rendered by Helm.
- **Why wrong:** outside a Helm chart, `{{ ... }}` is not interpreted — it stays as literal
  text and makes the YAML invalid, so `kubectl apply -f` would fail. The agent reused a Helm
  idiom out of its valid context.
- **How caught:** reviewer noticed the file lives under `platform/` (applied with kubectl),
  not under `deploy/charts/` (rendered by Helm).
- **Fix:** replaced the Helm comment with a plain `#` YAML comment.

## 2. Resilience4j starter pinned without verifying Spring Boot 4 compatibility

- **Produced:** `orders` and `payments` `build.gradle.kts` depend on
  `io.github.resilience4j:resilience4j-spring-boot3:2.3.0` while the project targets
  **Spring Boot 4.0.3**.
- **Why potentially wrong:** the `-spring-boot3` starter is published for the Boot 3 line; its
  auto-configuration may not bind on Boot 4 (package/auto-config relocation). Accepting the
  version blindly risks a context-startup failure or silently inactive circuit breakers.
- **How caught:** flagged at authoring time — annotated directly in the build file as
  "verify on first build".
- **Fix (pending Phase 2):** confirm at first `./gradlew build`; if incompatible, switch to a
  Boot-4-compatible Resilience4j release or wire CircuitBreaker/Retry programmatically via the
  core modules.
- **Resolution (2026-06-10): RESOLVED with evidence.** A green `contextLoads` was judged
  insufficient (the auto-configuration could back off silently, leaving `@CircuitBreaker`
  annotations inert), so we added a build-breaking assertion in `OrdersApplicationTests`
  that the `CircuitBreakerRegistry` bean actually exists. It passes on Spring Boot 4.0.3 +
  Resilience4j 2.3.0. Functional open/half-open behaviour is now exercised in Phase 2 #1
  (`PaymentsCircuitBreakerTest` drives CLOSED→OPEN→HALF_OPEN→CLOSED on the configured `payments`
  instance; `PaymentsGatewayBreakerIntegrationTest` proves the real gateway opens and fast-fails
  end-to-end against an unreachable Payments). To eliminate the residual AOP risk entirely we apply
  the breaker **programmatically** via the registry rather than the `@CircuitBreaker` annotation
  (see design.md decision 7).

## 3. (Reserved) readiness vs liveness probe scoping

- **Watch item:** an agent commonly proposes a `livenessProbe` that transitively checks a
  downstream dependency (DB/Kafka), which causes cascading restarts during a transient
  downstream blip — the exact anti-pattern the capstone calls out.
- **Our current stance:** liveness checks only `/actuator/health/liveness` (process self);
  readiness includes the owned DB (`group.readiness: readinessState,db`) but **not** Kafka, so
  broker blips don't flap the sync entry API. To be re-verified once handlers exist and during
  the latency/partition chaos experiments.
- **Status: OPEN** until validated under chaos.

## 4. Thin `justfile` that ignored the team's established Lab01 convention

- **Produced:** an initial `justfile` with only `test`/`build`/`run`/`image` shortcuts — no
  local DoD verification, no `docker-run`/`docker-stop`/`health-check`, no `.dockerignore`.
- **Why wrong:** Lab01 **explicitly required** (Step 2 + Step 4 + DoD item 4) the `justfile` to
  be the "versioned interface for recurring tasks" with a single recipe that verifies the DoD
  locally end-to-end (build → test → image → run → wait → health → cleanup), and Step 3
  explicitly required a `.dockerignore`. The team's own Lab01 `justfile` already did all this
  (`verify-local`, `act-ci`, JaCoCo, hooks). The agent produced something below the team's own
  established standard.
- **How caught:** teammate flagged that the Lab01 `justfile` was richer; we re-read the Lab01
  brief and confirmed the convention was prescribed, not optional.
- **Fix:** rewrote the `justfile` with `set shell`, `docker-run`/`docker-stop`/`health-check`,
  and a `verify <svc>` / `verify-all` 7-step DoD flow with `trap` cleanup (adapted to 5 services,
  no frontend); added `.dockerignore` to every service. Validated with `just --list`.

## 5. "HA" databases that silently used asynchronous replication — RPO > 0 on the invariant store

- **Produced:** `databases.yaml` Cluster CRs labelled "money path → HA" with `instances: 2`,
  relying on CloudNativePG's **default asynchronous replication**.
- **Why wrong (subtly):** with async replication a primary failover can lose the last
  committed transactions (RPO > 0). For inventory this breaks the exact invariant the design
  claims to protect: a committed reservation can vanish on failover, the seat counter rolls
  back, and the seat is sold twice — "never oversell" would fail precisely under chaos
  experiment #5 (CNPG primary failover). The atomic conditional UPDATE protects against
  *concurrency*, not against *losing committed state*. "More instances" looked like more
  safety while the consistency claim (CP / PC-EC) was not actually implemented.
- **How caught:** design review of the configuration against our own PACELC statement
  ("best configuration" pass, 2026-06-10): we asked "what does a failover do to a committed
  reservation?" and the default answer was "it can disappear".
- **Fix:** `inventory-db` → synchronous replication (3 instances, ANY 1,
  `dataDurability: required`, RPO=0; writes block if the primary is isolated — consistency
  over availability, as stated). `orders-db` → synchronous `preferred` (RPO=0 while healthy,
  degrades to async rather than blocking intake). Documented in `design.md` #4.12; requires
  CNPG ≥ 1.25.

## 6. Lost state transitions: `@Modifying(clearAutomatically = true)` silently dropped unflushed entity changes

- **Produced:** `InventoryService.release()` set `reservation.status = RELEASED` (relying on
  Hibernate dirty checking) and then called the bulk-update `restock()`, whose
  `@Modifying(clearAutomatically = true)` **cleared the persistence context before the status
  change was ever flushed**. The transition was lost: the row stayed `RESERVED` in the DB, so
  a second `release()` restocked the seats AGAIN — double restock, phantom availability,
  oversell risk from the compensation path. Same latent bug in `confirm()` (expired branch)
  and in the reconciler sweep (which would have re-expired the same holds every pass).
- **Why subtle:** every individual piece looks correct; the bug is the *ordering interaction*
  between dirty checking and bulk-update context clearing. The happy-path tests all passed —
  only the idempotency test (`release restocks and is idempotent`, expected 10, got 14)
  exposed it.
- **How caught:** the test suite written alongside the code (2026-06-10), specifically the
  idempotent-replay assertions. This is why idempotency tests are non-negotiable on the
  money path.
- **Fix:** `flushAutomatically = true` on the bulk updates, explicit `save()` of transitions
  before any bulk update, and the sweep persists ALL transitions before the first restock
  (the clear detaches the remaining entities mid-loop). All 12 inventory tests green,
  including 8-thread last-seat and concurrent-duplicate races.

## 7. Phase 2 #1 first cut: the circuit-breaker fallback masked permanent faults and the recovery sweep had unsafe edges

- **Produced (2026-06-25):** the initial #1 implementation (circuit breaker + `PAYMENT_PENDING` + recovery
  sweep) mapped EVERY exception from Payments to the `UNAVAILABLE` fallback, swept the whole batch of parked
  orders inside one try/catch, and shipped no test for the `@Version` concurrency it relies on.
- **Why wrong (caught by an adversarial multi-agent review of the diff):**
  1. **A 4xx parked the order forever.** A deterministic client error (`HttpClientErrorException`) was ignored
     by the breaker (correct) but still rethrown and swallowed into `UNAVAILABLE`, so the sweep retried it every
     5s with the identical result — an infinite `PAYMENT_PENDING`. Fix: a dedicated `catch (HttpClientErrorException)`
     maps a 4xx to a terminal `DECLINED` (`PaymentsGateway4xxTest`).
  2. **The recovery sweep widened a money leak.** On a long outage the inventory hold (TTL 2m) expires while the
     order is parked; the sweep would then re-authorize (CHARGE) and fail confirm (EXPIRED) with no refund until
     #4. Fix: the sweep bounds the park by age and rejects an expired hold WITHOUT charging
     (`OrderRecoverySweeperTest`); the residual sub-second window is made observable
     (`orders_charge_without_refund_total`).
  3. **One failing order aborted the whole sweep batch.** A single outer try/catch meant a lost `@Version` race
     (an EXPECTED outcome on multi-pod sweeps) skipped every later order in that pass. Fix: per-order isolation.
  4. **The load-bearing `@Version` had zero coverage** — sequential replay never fires it. Fix: an 8-thread
     concurrent-confirm test asserts exactly one terminal event survives (`OrderVersionConcurrencyTest`).
- **How caught:** four parallel reviewer agents over the diff (r4j-correctness, concurrency, saga-resume,
  quality/tests); the high-confidence findings were verified true and fixed, each pinned by a new test.
- **Fix:** all of the above; the orders suite went 15 → 20 tests, all green. Open follow-up: the Flyway V2 +
  Hibernate `validate` path is still only exercised on H2; validating it on the real postgres profile
  (Testcontainers) is deferred to the cluster phase.

## 8. Phase 2 #3 test used a Spring test slice (`MockMvc`) absent from the Boot-4 classpath

- **Produced (2026-06-26):** the first cut of `OrdersIntakeRateLimiterTest` exercised the 429 via
  `@AutoConfigureMockMvc` + `MockMvc` (`org.springframework.test.web.servlet.*`).
- **Why wrong:** the orders module's test dependencies are the **sliced** Boot-4 test starters
  (`spring-boot-starter-webmvc-test`, `…-data-jpa-test`), which do **not** bring `MockMvc` /
  `@AutoConfigureMockMvc` — the build failed at `compileTestKotlin` (`Unresolved reference 'web'`).
  The agent reached for a familiar idiom without checking it was on the classpath, and it also
  diverged from this project's established style (every other test drives the controller/saga bean
  **directly**, e.g. `CatalogControllerTest`, `OrderSagaTest`).
- **How caught:** `./gradlew test` (compile failure) — i.e. the build itself, before the change could
  be pushed. A green-looking plan is not a green build.
- **Fix:** rewrote the test in the project's direct-call style — autowire `OrdersController`, assert
  202 → shed (counter `orders_intake_shed_total` +1) → `IntakeOverloadedException`, then invoke the
  `@ExceptionHandler` directly to assert HTTP 429 + the `Retry-After` header. No extra test dependency;
  consistent with the codebase. Orders suite now green including the new test.

## 9. Phase 2 #4 first design: "reject-always + counter" only OBSERVED the money leak, it never CLOSED it

- **Produced (2026-06-26):** the first #4 design (refund/void compensation) added an idempotent
  `AUTHORIZED→VOIDED` transition on the existing Payments aggregate and, in the saga's expired-hold branch,
  called `payments.void(id)` then **always** `reject(RESERVATION_EXPIRED)`, incrementing
  `orders_charge_without_refund_total` when the void failed. The core (no reversal table, reuse of the
  `payments` Resilience4j instance, no migration, no Kafka event) was sound.
- **Why wrong (caught by an adversarial 3-lens review of the design BEFORE coding):**
  1. **A failed void leaked permanently.** On a sustained Payments outage the shared breaker is already OPEN,
     so the void fast-fails to `UNAVAILABLE`; `reject` is terminal and `OrderRecoverySweeper` only re-drives
     `PAYMENT_PENDING` — so the charge was never retried and never reversed. "Money-observable" is not
     "money-safe". Fix (team-chosen **Option B**): a failed void no longer rejects — it **parks**
     (`markPaymentPending`) so the existing recovery sweep re-drives the saga and **retries the void** until it
     succeeds, then rejects. Bounded by `app.recovery.max-park`. No new state, reuses the existing loop.
  2. **The sweeper's max-park-expiry reject was an INVISIBLE leak.** A crash after a re-authorize-on-sweep but
     before the void left a live charge; once past max-park the sweeper rejected WITHOUT voiding and WITHOUT
     any metric. Fix: the expiry path now attempts an idempotent best-effort `payments.void(id)` first
     (no charge → 404/no-op; a live charge → reversed).
  3. **A crash between void and reject mis-parked the order ~2 min and spammed false "unexpected status".**
     The replayed `authorize` returns the new `VOIDED` status, which fell into the saga's `else` (park) branch.
     Fix: a `"VOIDED" -> reject(RESERVATION_EXPIRED)` branch in the stage-2 dispatch (a VOIDED replay = already
     compensated → finish the rejection).
  Minor fixes folded in: a dedicated `payments_voids_total{outcome}` meter (don't pollute the authorize RED
  series), a 4-branch gateway fallback mirroring `authorize` (keep `bulkhead_full` distinct, map void 404 →
  benign `NOT_FOUND`), and reuse of `AuthorizationResult` for the gateway `void` (no redundant `VoidResult`).
- **How caught:** three parallel reviewer agents over the design (idempotency-correctness, codebase-consistency,
  antipattern-theory) returned a unanimous "sound-with-fixes"; the two majors (leak windows) and the
  crash-window were verified true against the source and incorporated before implementation.
- **Fix:** all of the above, each pinned by a test — `OrderSagaTest` gained the compensation (#5.4),
  failed-void-parks-then-rejects, and VOIDED-replay cases; `PaymentsServiceTest` gained void idempotency /
  no-op-on-declined / not-found. Orders 27 → 30 green, Payments 7 → 11 green. The lost-update guard
  (`@Version`/conditional UPDATE) on the void transition is deferred (money-safe today — no external
  side-effect — and adding it would break the migration-free property); recorded as a follow-up in `design.md`.

## 10. Coherence audit: the inventory restock had NO optimistic-lock guard → oversell under ≥2 replicas

- **Produced (Fase 1, surfaced by a 5-lens read-only audit 2026-06-26):** the never-oversell invariant was
  protected on the RESERVE side (atomic conditional `tryDecrement`) but the inverse RESTOCK side was left
  unguarded. `InventoryItemRepository.restock` is an **unconditional additive** `available = available + qty`,
  and `confirm`/`release`/`expireOverdue` did a **read-status-then-write** (`status==RESERVED` check) with **no
  `@Version`** on `Reservation` and no row lock — while `OrderRecoverySweeper`'s symmetric multi-pod race had
  been guarded with `@Version` on `Order` (decision 7/V2).
- **Why wrong:** inventory runs `replicaCount: 2` (no leader election), so two reconcilers — or a late `confirm`
  racing the reconciler (even in ONE pod: request thread vs reconciler coroutine) — both read the same
  RESERVED+expired hold, both flip it EXPIRED (UPDATE by id, no guard), and **both restock** (+qty twice). The
  additive restock is **non-convergent**, so the convergence argument that (correctly) lets `PaymentAuthorization`
  skip `@Version` (an idempotent overwrite, #4/#9) does **not** transfer here. Result: phantom availability → the
  next reserve oversells, breaking the headline invariant (`V1` only CHECKs `available >= 0`, no upper bound).
- **How caught:** the audit's idempotency/money-path lens flagged it (single-sourced); we then **verified it on
  the source** and **proved it with a failing test** — a new multi-transaction test in `InventoryConcurrencyTest`
  (8 concurrent `expireOverdue` / `confirm`-vs-sweep on one hold) asserts a SINGLE restock; with `@Version` removed
  it fails (double-restock), with `@Version` it passes.
- **Fix:** `@Version` on `Reservation` + `V3__add_reservation_version.sql`. The existing
  `@Modifying(flushAutomatically = true)` on `restock` makes the versioned reservation UPDATE flush **before** the
  additive restock, so a stale-version loser throws `ObjectOptimisticLockingFailureException` and rolls back
  **before** restocking. `confirm`/`release` map a lost race to a clean re-read of the now-terminal state (200,
  not a spurious 5xx) via `InventoryController`; the reconciler's batch rolls back and self-heals next sweep.

## 11. Coherence audit: #4 first cut left a dangling metric and an abandoned-charge boundary

- **Produced (Fase 2 #4):** `design.md` decision 7 #1 claimed the residual money-leak window was "observable via
  `orders_charge_without_refund_total`", but #4 had **removed that counter from the code** (replaced by
  `orders_compensations_total` / `payments_voids_total`) — a canonical doc pointing at a non-existent metric. The
  sweeper's max-park-expiry path also did a best-effort void then **rejected unconditionally**, so a still-down
  Payments left a possibly-live charge abandoned, uncounted — inconsistent with the saga's own stage-3
  park-on-failed-void. Separately, `orders_compensations_total{type=refund}` could **over-count** under concurrent
  drivers because the saga ignored the void's `replayed` flag.
- **Why wrong:** deck 10 — every policy must emit an accurate, alertable signal; a doc that references a dead
  metric and a leak window that is only WARN-logged both violate that. The two saga drivers disagreeing on the
  same outcome is an internal incoherence.
- **How caught:** the audit's observability + antipattern lenses; verified against the source.
- **Fix (team decision = Option B, money-safety over bounded retention):** the sweeper now rejects at max-park
  only when the money state is **resolved** (`VOIDED`/`NOT_FOUND`/`DECLINED`) and **keeps the order parked + retries
  the void** when Payments is unreachable (`orders_recovery_total{outcome=void_retry}`); `design.md` updated to the
  real metrics and the retention tradeoff; the compensation counter is gated on `!replayed` in both drivers.

---

_Add new entries as they happen. Aim well past the required three; every caught mistake is
evidence of ownership._
