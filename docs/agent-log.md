# Agent verification log

> **Capstone rule (graded).** Agentic tools are permitted and encouraged, but the team must **verify** the
> output and **show where the agent was wrong**. This file records concrete cases where an agent-produced
> artifact (code, config, design, plan) was incorrect, unsafe, or subtly wrong, and how we caught and fixed it.
> *"Finding the agent's mistakes is the core skill the capstone certifies."*
>
> These seven are the strongest, most instructive cases — real design/correctness/observability defects, not
> style nits. Each is written to be understood on its own. Format: **What the agent produced → Why it was wrong
> → How we caught it → The fix → The lesson.**

---

## 1. "HA" databases that silently used asynchronous replication — RPO > 0 on the store that holds the invariant

- **What the agent produced.** The CloudNativePG `Cluster` definitions for the money-path databases, labelled
  "money path → HA", with `instances: 2` and nothing else — so they ran on CloudNativePG's **default
  asynchronous replication**.
- **Why it was wrong.** "More instances" looks like more safety, but with async replication a primary failover
  can lose the last transactions that were committed on the primary but not yet shipped to the replica
  (**RPO > 0**). For `inventory` that silently breaks the one invariant the whole design is built to protect: a
  committed seat reservation can vanish on failover, the seat counter rolls back, and the seat gets sold twice.
  The atomic conditional `UPDATE` protects against **concurrency**, but not against **losing already-committed
  state** — a completely different failure. So the config looked HA while the consistency claim (CP / PC-EC) was
  not actually implemented, and it would have failed precisely under chaos experiment #5 (primary failover).
- **How we caught it.** A design review that checked the configuration against our own PACELC statement. We asked
  one concrete question — *"what does a failover do to a committed reservation here?"* — and the honest answer was
  *"it can disappear"*.
- **The fix.** `inventory-db` → **synchronous** replication (3 instances, `ANY 1`, `dataDurability: required`,
  RPO=0): a write is not acknowledged until a standby has it, so a failover loses nothing; if the primary is
  isolated, writes **block** rather than risk loss — consistency over availability, exactly as stated.
  `orders-db` → synchronous `preferred` (RPO=0 while healthy, degrades to async instead of blocking intake, since
  the invariant does not live in orders-db). Requires CNPG ≥ 1.25.
- **The lesson.** A replica count is not a durability guarantee. When a store holds a correctness invariant, the
  replication **mode** (sync vs async) is the design decision — and the default is async.

## 2. A bulk-update flag silently threw away un-flushed state changes → double restock → oversell

- **What the agent produced.** `InventoryService.release()` set `reservation.status = RELEASED` (relying on
  Hibernate dirty-checking to persist it later) and then called the bulk-update `restock()`. That repository
  method carried `@Modifying(clearAutomatically = true)`.
- **Why it was wrong.** `clearAutomatically = true` **clears the persistence context before the pending status
  change was ever flushed to the database**. So the transition was lost: the row stayed `RESERVED`, and a second
  `release()` restocked the seats **again** — a double restock that invents phantom availability, which then lets
  the next reservation oversell. The bug is not in any single line; it is the **ordering interaction** between
  dirty-checking (defers the write) and `clearAutomatically` (discards the deferred write). The same latent bug
  existed in `confirm()` (expired branch) and in the reconciler sweep.
- **How we caught it.** The happy-path tests all passed — only the **idempotency test** (`release restocks and is
  idempotent`) caught it: it expected 10 seats back and got 14. This is exactly why idempotency/replay tests are
  non-negotiable on the money path.
- **The fix.** `flushAutomatically = true` on the bulk updates (flush the transition **before** the context is
  cleared), plus an explicit `save()` of each transition before any bulk update. All inventory tests green,
  including the 8-thread last-seat and concurrent-duplicate races.
- **The lesson.** Each piece can be individually correct while their **interaction** is a data-loss bug; only a
  test that asserts the after-state of a *repeated* operation surfaces it.

## 3. The restock side had no optimistic-lock guard → oversell once inventory runs ≥ 2 replicas

- **What the agent produced.** Never-oversell was protected on the **reserve** side (the atomic conditional
  `tryDecrement`), but the inverse **restock** side was left unguarded: `restock` is an unconditional additive
  `available = available + qty`, and `confirm`/`release`/`expireOverdue` did a **read-status-then-write** (`if
  status == RESERVED …`) with **no `@Version`** and no row lock on `Reservation`.
- **Why it was wrong.** Inventory runs **2 replicas** with no leader election, so two reconcilers — or a late
  `confirm` racing the reconciler (even inside one pod: request thread vs reconciler coroutine) — can both read
  the same expired-but-`RESERVED` hold, both flip it to `EXPIRED`, and **both restock (+qty twice)**. Because the
  restock is *additive* (non-convergent), the argument that lets `PaymentAuthorization` safely skip `@Version`
  (an idempotent overwrite) does **not** transfer here. Result: phantom seats → the next reserve oversells — the
  headline invariant broken from the compensation side.
- **How we caught it.** A read-only coherence audit flagged it (the reserve side was guarded, the restock side
  wasn't); we then **proved it with a failing test** — 8 concurrent `expireOverdue`/`confirm`-vs-sweep on one
  hold asserting a *single* restock. With `@Version` removed it fails (double restock); with `@Version` it passes.
- **The fix.** `@Version` on `Reservation` (+ migration). The existing `flushAutomatically` on `restock` makes the
  versioned reservation UPDATE flush **before** the additive restock, so a stale-version loser throws
  `ObjectOptimisticLockingFailureException` and rolls back **before** restocking; a lost race re-reads the now-terminal
  state cleanly (200, not a spurious 5xx).
- **The lesson.** An invariant has two sides. Guarding the obvious one (decrement) is not enough when the inverse
  (restock) is additive and runs on multiple replicas.

## 4. The circuit-breaker fallback masked permanent faults, and the recovery sweep had money-leak edges

- **What the agent produced.** The first cut of the Orders→Payments resilience (circuit breaker + a
  `PAYMENT_PENDING` parking state + a recovery sweep) mapped **every** exception from Payments to an
  `UNAVAILABLE` fallback, swept the whole batch of parked orders inside a single try/catch, and shipped no test
  for the `@Version` concurrency it relied on. *(This is now historical: the sync Orders→Payments call — and this
  breaker — were retired when the money path became an async Kafka saga. The mistakes it made are still the point.)*
- **Why it was wrong** (found by an adversarial review of the diff):
  1. **A client error parked the order forever.** A deterministic 4xx from Payments was mapped to `UNAVAILABLE`,
     so the sweep retried it every few seconds with the identical result — an infinite `PAYMENT_PENDING`. A 4xx is
     terminal information, not a transient outage.
  2. **The recovery sweep widened a money leak.** On a long outage the inventory hold expires while the order is
     parked; the sweep would then **re-authorize (charge) and fail confirm** (hold expired) with no refund.
  3. **One failing order aborted the whole sweep.** A single outer try/catch meant one lost `@Version` race (an
     *expected* outcome across pods) skipped every later order in that pass.
  4. **The load-bearing `@Version` had zero coverage** — sequential tests never exercise a concurrent race.
- **How we caught it.** Parallel reviewer agents over the diff (resilience-correctness, concurrency, saga-resume,
  tests); each high-confidence finding was verified against the source and then **pinned by a new test**.
- **The fix.** A dedicated 4xx→terminal `DECLINED` path; the sweep bounds parked orders by age and rejects an
  expired hold **without** charging; per-order isolation in the sweep; and an 8-thread concurrent-confirm test
  asserting exactly one terminal event survives. Orders suite 15 → 20 tests, all green.
- **The lesson.** A fallback that turns *every* failure into "temporarily unavailable" hides the failures you must
  treat differently (permanent vs transient), and a batch recovery loop needs per-item isolation and an explicit
  money-safety bound.

## 5. Two "consolidation" merge PRs shipped four regressions that green CI never caught

- **What the agent produced.** One PR per repo that merged parallel branches without reconciling them against the
  in-flight Phase-3 work. The merges introduced four concrete defects, none caught by the (green-but-trivial) CI:
  1. **Domain regression.** A `values.yaml` conflict was resolved toward the stale side, **silently reverting** the
     working ingress host back to a placeholder → Let's Encrypt can't validate → TLS never issues.
  2. **Duplicate `ClusterIssuer`.** Two definitions of the same cluster-scoped `letsencrypt-prod` with **different
     ACME emails** → applying both is last-write-wins / non-deterministic.
  3. **CI broken for every real change.** `detect-changes` exported invalid JSON (the JSON's own quotes terminated
     the shell string), so the build matrix threw and the run died in ~12s — but only when a push actually touched
     `services/**`, which is why earlier docs-only pushes looked green.
  4. **Doc/pin drift.** A README cited a non-existent registry; a CNPG version was pinned in one file and missing
     from the file named as the source of truth.
- **Why it was wrong.** A merge is not a no-op: resolving a conflict toward the stale side **undoes a committed
  fix**, and a pipeline that is "green" only because its build path never executes proves nothing.
- **How we caught it.** A read-only re-audit of both repos **after** the PRs — branch diffs, CI run history, and a
  trace of the `fromJSON` failure — not by CI, which reported a 12-second failure with no actionable log.
- **The fix.** Pass the changed-services list via an env var (valid JSON → matrix parses); consolidate to one
  `letsencrypt-prod` issuer with the real email; correct the registry/version references; reset the ingress host to
  the live value.
- **The lesson.** Trust `git`, not the merge narrative: after a non-trivial merge, diff the result against what was
  known-good, and make sure CI actually **exercises** the artifact instead of skipping the build.

## 6. The agent's "GitOps-native canary" was hand-rolled delivery infra — and it only governed HTTP

- **What the agent produced.** A progressive-delivery design where the canary weight was a number edited in
  `values.yaml` and moved by hand, presented as a virtue ("the weight is a commit, fully auditable").
- **Why it was wrong** (two separate misses):
  1. **It re-implemented the delivery control loop by hand.** The "promotion controller" of that design was a human
     watching Grafana and committing weight bumps. That is exactly the kind of infrastructure we are supposed to use
     a real tool for — the same bias as hand-rolling a polling outbox relay instead of using CDC. With no automated
     analysis, nothing reacts to a canary burning error budget at 3am.
  2. **In the async saga, a traffic weight does not bound the blast radius.** Canary/green pods join the **same
     Kafka consumer group** as stable, so at weight 0 the canary still consumes saga replies and advances **real**
     orders, and a full-capacity green consumes ~half the partitions **before** the "atomic" switch. The live
     30/06 validation measured exactly what the design promised and therefore could not reveal what it failed to say.
- **How we caught it.** A team prod-grade re-evaluation (not the agent, unprompted): we asked whether the mechanism
  was a real controller and what a canary actually isolates in an event-driven system.
- **The fix.** **Argo Rollouts**: the policy (steps, pauses, analysis queries) lives in Git, the execution (moving
  weights, querying Prometheus, promoting/aborting) is the controller's — every CI tag bump is now an SLO-gated
  release with automatic abort. The async gap is handled by bounding canary consumer exposure
  (`setCanaryScale: 1`), gating the analysis on the **canary pods' Kafka listener failure rate**, and documenting
  the release invariant (event compatibility between adjacent versions).
- **The lesson.** Validating that a mechanism does what its design *says* is necessary but not sufficient; the graded
  question is what the design **fails to say** — here, that an HTTP weight doesn't canary a shared consumer group.

## 7. Tracing looked wired but exported nothing — Spring Boot 4 renamed the OTLP endpoint property

- **What the agent produced.** The tracing setup carried over from Boot 3: the app declared the tracing/OTLP
  dependencies, set `management.tracing.sampling.probability: 1.0`, and pointed
  `management.otlp.tracing.endpoint` at the collector. Everything *looked* configured.
- **Why it was wrong.** The first AKS run showed `traceId`/`spanId` in every log line (so the tracer was active
  and sampling) — yet the collector received **zero spans** and no service logged an export error. Boot 4 moved the
  OTLP tracing endpoint property to `management.opentelemetry.tracing.export.otlp.endpoint`. With nothing bound at
  the new name, `OtlpTracingAutoConfiguration` creates **no exporter at all** — which is why it failed *silently*:
  no exporter means no export attempts, so not even a connection-refused error. (Same Boot-4 modularization also
  meant the tracing auto-config only activates with the dedicated `spring-boot-micrometer-tracing-opentelemetry`
  module — without it the deps were inert.)
- **How we caught it.** By validating the **sink**, not the app: we checked whether the collector actually received
  spans, instead of trusting the in-process evidence (log traceIds prove the tracer, not the pipeline).
- **The fix.** Inject the Boot-4 property name from the chart (kept alongside the old name until the app yml dropped
  its stale key). Cross-Kafka traces then appeared end-to-end in Tempo.
- **The lesson.** "Dependency on the classpath + property set" does not mean "feature active". A major-version
  framework upgrade relocates both auto-configurations and property names, and the failure mode is **silent** — so
  the proof must be positive (data at the sink), never the absence of errors.

---

_Team-owned. New entries are added as real mistakes are caught; the bar is a genuine defect, verified against the
source and (where it's code) pinned by a test._
