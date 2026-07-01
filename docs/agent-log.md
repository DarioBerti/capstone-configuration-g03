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
- **Update (2026-06-30): the AOP risk is closed at the source.** Resilience4j **2.4.0** shipped a
  dedicated **`resilience4j-spring-boot4`** artifact (depends on Spring Boot 4.0.0 / Spring Framework
  7.0.2 — verified on Maven Central), so the annotation aspects are officially supported on our Boot
  4.0.3. We bumped **`orders`** to it and added `spring-boot-starter-aop`, then migrated the intake
  rate limiter from the programmatic `OrdersIntakeRateLimiter` to the **`@RateLimiter` annotation** on
  `OrdersController.place()`. `OrdersIntakeRateLimiterTest` drives the proxied controller directly and
  proves the aspect actually fires on Boot 4 (2nd call → `RequestNotPermitted` → 429 + Retry-After) —
  a build-breaking proof, not a silent no-op. The gateway breaker/bulkhead/retry stay programmatic by
  **choice** now (explicit `Retry(CircuitBreaker(Bulkhead(…)))` composition, self-invocation safety,
  deterministic testability), not because annotations can't weave. `payments` still pins
  `resilience4j-spring-boot3:2.3.0` (programmatic-only, so it works); an optional consistency bump.

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

## 12. Phase 2 #5 gap-analysis: a "proven" property was only proven by composition, and one test loop was un-gated

- **Produced (interleaved with #1-#4):** the resilience test suite. A 3-lens gap-analysis of it against the #5
  acceptance criteria found two subtle weaknesses behind otherwise-green tests:
  1. **5.3 (retry is safe ONLY because idempotent) was asserted by COMPOSITION, never in one flow.**
     `PaymentsRetryIntegrationTest` fires the real retry but its stub 503s at the transport layer *before* any side
     effect (nothing is ever charged to dedup; it asserts the attempt *count*, not a charge), while
     `PaymentsServiceTest` dedups with two *direct* calls and no retry. No test modelled the slide-22 danger: a charge
     that **commits on the server then loses its response**, so the client retransmits onto an idempotent endpoint.
  2. **The inventory `ReservationReconciler` had NO enabled-gate** (unlike orders' `OrderRecoverySweeper`): the 3
     inventory `@SpringBootTest` were only *timing-safe* (the `PT15S` sweep outran sub-second tests), not gated. After
     the #1 oversell fix added tests that seed already-expired holds, that became a latent race against the seat-count
     assertions on a shared cached context.
- **Why it matters:** "a property you prove" (deck 11 s.41) is not proven if the proof is inferred across two tests
  in two services; and a test that passes only because a background loop happens to be slow is a flake waiting to fire.
- **How caught:** the gap-analysis (coverage map + gating audit + chaos-doc design), each finding verified against the
  source; the 5.3 gap was then made **falsifiable** (removing the stub's `putIfAbsent` dedup turns the new test red).
- **Fix:** new `PaymentsRetryIdempotencyIntegrationTest` (real gateway + idempotent stub + response-lost-after-commit →
  exactly one charge, build-breaking); `inventory.reservation.enabled` gate on `ReservationReconciler` mirroring
  `OrderRecoverySweeper`, set `false` in the 3 inventory tests (race-free by gating, not timing); plus the #5.6
  traceability doc (`docs/chaos/test-traceability.md`) + `@Tag("chaos-NN")` mapping each functional test to its
  anticipated cluster experiment.

## 13. Phase 3 — the two consolidation PRs (kind-cluster → config/main, backend-fixes → app/main) shipped four regressions

- **Produced (2026-06-28):** PR#1 on each repo merged parallel branches without reconciling against the in-flight
  Phase-3 work. The merges introduced four concrete defects, none caught by the (green-but-trivial) CI:
  1. **`global.domain` regression.** The kind-cluster branch carried the old placeholder `g03.cpo2026.it`; the merge
     resolved the chart's `deploy/charts/eurotransit/values.yaml` in its favour, **silently reverting** the working
     `158.158.71.17.sslip.io` set in 385a39b. Argo CD renders base `values.yaml` only → Let's Encrypt HTTP-01 can't
     validate the placeholder host → `eurotransit-tls` never issues (breaks §6.3 TLS).
  2. **Duplicate `letsencrypt-prod` ClusterIssuer.** The kind branch added `clusterissuer-prod.yaml` (placeholder
     email `team-g03@example.com`) while `clusterissuer.yaml` already defined `letsencrypt-prod` (real email). Two
     definitions of the same cluster-scoped resource with **different ACME account emails** → applying both is
     last-write-wins / non-deterministic.
  3. **CI build broken for every real change.** `app/.github/workflows/ci.yml` `detect-changes` did
     `echo "services=${{ steps.filter.outputs.changes }}"` — the JSON's own double-quotes terminate the bash string,
     exporting **invalid JSON**, so `fromJSON` in the build matrix throws and the whole run dies in ~12s before any
     image is built. It only surfaced now because the backend-fixes merge was the first push to change all five
     `services/**` folders (earlier pushes touched only ci.yml/docs → matrix empty → build skipped → false green).
  4. **Doc/pin drift:** `kind-registry/README.md` cited the non-existent `lab02g03registry.azurecr.io`; CNPG `1.29.1`
     was pinned in `design.md` §4b but missing from `platform/README.md` (the file §4b names as source of truth),
     violating the "never `latest`/pin in platform/README" rule.
- **Why wrong:** a merge is not a no-op — resolving a `values.yaml` conflict toward the stale side silently undoes a
  committed fix; and a CI that is "green" only because the build path never executes proves nothing (deck 08: a
  pipeline must actually exercise the artifact). The Phase-2 resilience (`app/fase-2`) was also left **unmerged**, so
  `app/main` after the PR was layer-folder layout **without** any circuit breaker/bulkhead/retry/429/void code.
- **How caught:** a read-only re-audit of both repos after the PRs (branch-diff + CI run-history + `fromJSON` trace +
  `git show origin/main:…values.yaml` history) — not by CI, which reported the 12s failure with no actionable log.
- **Fix:** ci.yml passes the list via a `CHANGES` env var (valid JSON → matrix parses); `clusterissuer-prod.yaml`
  email aligned to the real account (team to consolidate to ONE letsencrypt-prod file); `kind-registry/README.md` and
  `platform/README.md` (CNPG `1.29.1` row + new `cert-manager/`/`traefik/`/`kind-registry/` dirs) corrected;
  `design.md` §4b D-E rewritten to state the regression and that `global.domain` must be reset to the **current**
  Traefik LB IP (the old `158.158.71.17` belonged to the prior cluster). Phase-2 resilience was re-applied onto the
  layer-folder layout on `app` branch `fase-3-consolidation` (all 5 services compile; Testcontainers run pending).

## 14. Phase 3 — CI pushed to a registry the chart never pulls from (a fifth consolidation regression)

- **Found (2026-06-28):** a follow-up audit of the GitOps loop, after #13, surfaced a defect #13 missed:
  `app/.github/workflows/ci.yml` built and pushed to `env.REGISTRY: etg03registry.azurecr.io`, while the chart
  pulls every service from `labg03clusterregistry.azurecr.io` (`deploy/charts/eurotransit/values.yaml`
  `global.registry` + the five `services.*.image.repository`). A **third** registry name on top of the
  `lab02g03registry` ghost already corrected in #13.
- **Why wrong:** the CI bumps **only** `services.<svc>.image.tag`, never the repository — by design (immutable
  image, tag is the single CI-mutated field). So even on a green pipeline Argo CD would reconcile the chart to
  `labg03clusterregistry/eurotransit/<svc>:<sha>`, an image that was pushed to `etg03registry` and therefore does
  **not exist** there → `ImagePullBackOff` → the app never reaches Healthy. This is precisely the symptom logged in
  `FASI_PROGETTO.md` ("Argo Synced&Healthy bloccato su immagini ACR"): the blocker was a config split-brain, not a
  missing image build. A pipeline whose output address differs from what the deployer reads is dead on arrival
  (deck 08: build and deploy must agree on the artifact coordinate, not just the tag).
- **How caught:** read-only cross-repo diff of the image coordinate — `env.REGISTRY` in `ci.yml` vs `global.registry`
  + `image.repository` in `values.yaml` — not by CI (no job asserts the two registries match).
- **Fix:** `ci.yml` `REGISTRY` aligned to `labg03clusterregistry.azurecr.io` (the registry attached to the cluster
  per D-G; `ACR_USERNAME/ACR_PASSWORD` secrets must belong to it). Also **completed #13's open item**: the duplicate
  `platform/cert-manager/clusterissuer-prod.yaml` was deleted, leaving `clusterissuer.yaml` (staging+prod, real
  email) as the single AKS source — which also fits the staging→prod issuance chosen for the first cert.
  Open follow-up (not code): the `158.158.71.17.sslip.io` in `values.yaml` belonged to the **prior** cluster (#13);
  it must be re-confirmed against the live Traefik LB IP after `az aks start` before issuing the cert.

## 15. Phase 2 #7 — a new `@SpringBootTest` guard leaked shared-context state into a sibling test

- **What the agent produced:** `MetricCardinalityGuardTest` (orders, §7.3 low-cardinality guard). To register a
  real shed counter it shrank the intake budget via inlined `@SpringBootTest(properties=[… ratelimiter…
  limit-for-period=1 …])` — copying the **exact** property set already used by `OrdersIntakeRateLimiterTest`.
- **Why wrong:** Spring's test context cache keys on the merged config (inlined properties included). Identical
  properties → both classes **share one cached context** → one singleton `RateLimiter("orders-intake")`. The guard
  consumed the single per-window permit, so when the sibling ran in the same context its first `place()` (expected
  `202 ACCEPTED`) was shed → `OrdersIntakeRateLimiterTest` failed. Green in isolation, red in the full suite — the
  worst kind: a test that only fails when run with its neighbours.
- **How caught:** running the **whole** orders suite, not just the two new tests (`./gradlew test` → `34 tests,
  1 failed`). Running only the new tests had passed and would have shipped the leak.
- **Fix:** made the guard's property set **distinct** (`limit-for-period=2`, consume 2 then shed) so it gets its
  **own** cached context — no shared singleton, no leak. Lesson: an inlined-property `@SpringBootTest` that mutates
  a singleton (rate limiter / breaker / registry) must not share a context with tests that assert on that
  singleton's fresh state; vary the config or `@DirtiesContext`.
- **Related (not a bug, a doc nuance):** the §7.5 note first claimed "`kubectl logs` shows JSON" as if already live.
  The cluster runs the Fase-3 image (`3af035e`), predating the structured-logging config → live logs are still
  plain; JSON ECS appears only after a CI rebuild. Doc corrected to say "post-deploy".

## 16. Phase 2 #6 live validation — topology spread is `ScheduleAnyway` (soft), so it co-located both payments replicas

- **What surfaced:** during the live §6 validation, `kubectl get pods -o wide` showed **both** `payments` replicas
  on the same node (`…00000d`), despite a `topologySpreadConstraints{maxSkew:1, topologyKey: hostname}`.
- **Why it matters:** the constraint uses `whenUnsatisfiable: ScheduleAnyway` → it is a **preference**, not a
  guarantee. The scheduler packed both pods on one node; a single node failure would take out the entire payments
  capacity — exactly the failure-domain co-location the spread is meant to prevent (deck 11: "replication protects
  only if replicas are across independent failure domains").
- **How caught:** reading live pod placement against node identity (not assuming the manifest's intent equals the
  runtime result). The chart *had* the constraint; only the live cluster revealed it wasn't binding.
- **Decision (team-owned, not auto-applied):** `DoNotSchedule` would make the spread a hard guarantee, but on a
  3-node cluster it risks unschedulable pods during a drain/upgrade. Trade-off availability vs hard anti-affinity —
  left as a documented finding for the team to resolve in `deploy/charts/eurotransit` + `docs/design.md`, not
  silently changed by the agent.

## 17. Phase 4 — agent almost overwrote a teammate's existing `chaos-mesh/README.md`

- **What the agent did:** while adding the five Chaos Mesh manifests it went to **write** a fresh
  `platform/chaos-mesh/README.md`, assuming the directory was new — but the folder already existed with a
  teammate's "Planned experiments" stub (scaffolding committed earlier on `main`).
- **Why wrong:** a blind `Write` would have **silently destroyed** the existing stub (and any intent in it),
  the classic agent failure of treating a path as empty without checking. On a shared repo that is lost work.
- **How caught:** the write-after-read guard refused (`File has not been read yet`). The agent then **read** the
  stub, saw it listed the same five experiments as "planned", and **edited** it into the delivered version
  (numeric-prefixed filenames matching `docs/chaos/0X`, safety model, run loop) instead of clobbering it.
- **Lesson:** before writing a file in a multi-person repo, assume it may already exist — read first; turn an
  overwrite into a merge/upgrade of what is there. (Also: the SLO targets were kept as **strings** in
  `values.yaml`, e.g. `"0.99"`, so they render verbatim into the PromQL expressions — floats risked a
  formatting surprise in the rule text.)

---

_Add new entries as they happen. Aim well past the required three; every caught mistake is
evidence of ownership._
