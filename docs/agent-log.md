# Agent verification log

> Capstone rule: agentic tools are permitted and encouraged, but the team must **verify** and
> **show where the agent was wrong**. This log records concrete cases where an agent-produced
> artifact was incorrect, unsafe, or subtly wrong, and how we caught and corrected it.
> *Finding the agent's mistakes is the core skill the capstone certifies.*

Format per entry: **what the agent produced → why it was wrong → how we caught it → the fix**.

> **This file is the curated extract — the 10 most critical caught mistakes** (money-path
> correctness, deploy blockers, parallel-agent contracts, and live-cluster findings), chosen for
> the oral/review. The **complete chronological record of every caught mistake** (33 entries) is
> preserved in [`agent-log-full.md`](agent-log-full.md) — read that for the full evidence of
> ownership.

---

## 1. "HA" databases that silently used asynchronous replication — RPO > 0 on the invariant store

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

## 2. Lost state transitions: `@Modifying(clearAutomatically = true)` silently dropped unflushed entity changes

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

## 3. Coherence audit: the inventory restock had NO optimistic-lock guard → oversell under ≥2 replicas

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
  skip `@Version` (an idempotent overwrite) does **not** transfer here. Result: phantom availability → the
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

## 4. Phase 2 #1 first cut: the circuit-breaker fallback masked permanent faults and the recovery sweep had unsafe edges

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

## 5. Phase 2 #4 first design: "reject-always + counter" only OBSERVED the money leak, it never CLOSED it

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
- **Fix:** all of the above, each pinned by a test — `OrderSagaTest` gained the compensation,
  failed-void-parks-then-rejects, and VOIDED-replay cases; `PaymentsServiceTest` gained void idempotency /
  no-op-on-declined / not-found. Orders 27 → 30 green, Payments 7 → 11 green. The lost-update guard
  (`@Version`/conditional UPDATE) on the void transition is deferred (money-safe today — no external
  side-effect — and adding it would break the migration-free property); recorded as a follow-up in `design.md`.

## 6. Phase 3 — the two consolidation PRs (kind-cluster → config/main, backend-fixes → app/main) shipped four regressions

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
  committed fix; and a CI that is "green" only because the build path never executes proves nothing (a
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

## 7. Async cutover — three parallel agents building both sides of a Kafka contract with no shared schema

- **What the agents produced (2026-06-30):** the sync→async money-path cutover (decision 13) was implemented
  by **three agents in parallel** — Payments (two-phase + outbox + listeners), Inventory (outbox + listeners),
  Orders (reply-driven saga). Each service keeps its **own copy** of the event payload `data class`es (the
  project's deliberate no-shared-module choice), so the producer and the consumer of every topic were written
  by **different agents who could not see each other's code**.
- **Why that is the risk:** the contract is enforced by nothing but matching strings — topic names, JSON field
  names, and the **status string literals** (`"RESERVED"`/`"SOLD_OUT"`/`"AUTHORIZED"`/…). A drift (one agent
  emitting `seats-confirmed` while another listens on `confirm-seats-result`, or a reply carrying
  `state` where the consumer reads `status`, or `"SOLDOUT"` vs `"SOLD_OUT"`) would compile cleanly, pass every
  in-process test (listeners are `autoStartup`-gated **off** in tests, so no test crosses the wire), and only
  fail **silently at runtime** — a reply that never matches, a status that falls into the `else`/ignored branch
  and wedges the saga. Each agent's own green suite proves nothing about the *seam between* services.
- **How we caught/prevented it:** (1) a **canonical contract was pinned up front** in each agent's brief
  (exact topic + field + status-literal spelling) rather than left to each agent to invent; (2) after all three
  returned green, the seam was **verified against the real source, not the agents' self-reports** — a sweep of
  the topic constants in every `events/Topics.kt`, the status string literals across all `service`/`events`
  code, and a leftover-reference grep (`PAYMENT_PENDING`, the retired `inventory-reserved`/`payment-authorized`
  topics, the deleted `gateway/` package). The union of topic constants used in code (17) was then checked to
  **exactly equal** the topic set in `platform/strimzi/kafka-topics.yaml` (no orphan topic, no missing CR).
- **Outcome:** no drift — the three independently-written copies aligned on every topic, field, and status
  value, and the old surface was fully removed. The lesson is the method, not a bug: when agents build opposite
  ends of an un-typed contract in parallel, the contract must be **fixed before fan-out and re-verified at the
  seam after** — a per-service green build is necessary but not sufficient. *(Follow-up worth considering: a
  cheap CI contract test, or a shared `:events` module / schema registry, would make this seam compiler- or
  test-enforced instead of review-enforced.)*

## 8. `dev` merge — parallel `Explore` subagents OVERESTIMATED the merge and INVENTED migration collisions

- **Produced:** the "collision map" from parallel `Explore` subagents claimed a **CRITICAL** textual conflict on
  `orders/V1__baseline.sql` (`product_id` vs `trip_code`), **version-number collisions** between our migrations and
  `dev`'s, and that `catalog`/`users` tests needed reworking.
- **Why wrong:** none of it was true. `dev` never touched the `V1` baselines (it only **added**
  `orders/V2__add_order_version.sql` and `inventory/V3__add_reservation_version.sql`): no baseline conflict, no
  version-number clash (migrations are additive and stack). `catalog`/`users`/`notifications` are untouched by `dev`'s
  12 commits, so they auto-merge in full. The subagents reasoned over the **shape of the diff** (`git diff base..dev`)
  instead of the real three-way merge.
- **How caught:** running `git merge-tree --write-tree origin/dev database_refactor` **before** picking a strategy —
  an authoritative dry-run merge that returned the real conflict set: exactly 20 files confined to
  `inventory`/`orders`/`payments`, **zero** migration conflicts, `catalog`/`users`/`notifications` clean.
- **Fix:** planned and executed against `merge-tree`'s real set, not the agents' map. The migrations stacked
  additively (our `V1` + `dev`'s `V2`/`V3`) with no manual reconciliation.
- **Lesson:** an agent's "merge analysis" is speculation over diffs; the authoritative answer is a tool —
  `git merge-tree` (a dry-run merge). Run the tool first and trust **it** over the agent's narrative, especially for
  additive migrations, where the subagents over-alarmed.

## 9. Boot-4 tracing dependencies were INERT — the auto-config module was missing

- **Produced:** Phase 4, cross-Kafka tracing. All services had declared `micrometer-tracing-bridge-otel` +
  `opentelemetry-exporter-otlp` for weeks and configured `management.tracing.sampling.probability: 1.0` and
  `management.otlp.tracing.endpoint` — and the roadmap said "pipeline proven, the apps must export spans". An agent's
  first wiring attempt stopped there, assuming deps + properties were enough.
- **Why wrong:** in **Spring Boot 4** the tracing auto-configuration no longer lives in
  `spring-boot-actuator-autoconfigure` (as in Boot 3) but in the dedicated module
  **`spring-boot-micrometer-tracing-opentelemetry`** (which pulls `spring-boot-micrometer-tracing` +
  `spring-boot-opentelemetry`). Without that module **no `Tracer`/`Propagator`/OTLP-exporter bean is created**: the deps
  and properties were a silent no-op — zero spans exported, MDC without traceId/spanId, and no error anywhere.
- **How caught:** a new test (`SagaCompletionMetricsTest`) that injects `Tracer` failed with
  `No qualifying bean of type 'io.micrometer.tracing.Tracer'`; a classpath inspection (`gradlew dependencies`) showed
  that NO boot tracing module was present — so the problem wasn't "the tests disable tracing", it was that tracing
  didn't exist in production either.
- **Fix:** added `org.springframework.boot:spring-boot-micrometer-tracing-opentelemetry` to all six services (the
  existing properties stay valid: the module still supports the `management.otlp.tracing.*` aliases). Verified with the
  full suite (`just test-all`, 6/6 green) and with the test asserting the W3C `traceparent` persisted in the outbox row.
- **Lesson:** "dependency on the classpath + property configured" does NOT imply "feature active": major upgrades move
  auto-configurations. The proof must be **positive** (an injected bean, a visible span), never the absence of errors.

## 10. Fase 5 live — the first real AKS canary auto-aborted on a NaN false positive (the mechanism worked, the signal lied)

First template-change rollout on AKS with analysis enabled: the controller aborted at step 0 — weights back
to 100/0 stable with zero human action, which is the Fase-5 mechanism proven live — but the failed gate was
a false positive. The success-rate query guards the no-traffic case with `or vector(1)`, which only fires
when the result is EMPTY (no series). The canary had received a handful of early requests, so its series
EXISTED; when the smoke token expired mid-ramp (401s land on uri="UNKNOWN", outside the query) the 2m rate
windows went 0/0 = **NaN — a present sample the vector() guard cannot replace**, and `NaN >= 0.99` is false:
4 consecutive Failed measurements -> abort. **Fix:** `isNaN(result[0]) || ...` in every successCondition
(the pattern Argo Rollouts documents for exactly this). **Lesson:** PromQL has TWO distinct "no data"
shapes — empty vector and NaN sample — and a gate must be immune to both; a canary with no traffic is
"no evidence of failure", never "failure". *(This live incident is written up in full as the blameless
[`postmortem.md`](postmortem.md).)*

---

_This is the curated top-10. Add new caught mistakes to [`agent-log-full.md`](agent-log-full.md) as they
happen — every caught mistake is evidence of ownership — and promote the most instructive ones here._
