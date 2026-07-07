# Agent verification log

> Capstone rule: using AI agents is allowed and encouraged, but the team must **verify their output** and
> **show where the agent was wrong**. This log records concrete cases where an agent-produced artifact was
> wrong, unsafe, or subtly broken — and how we caught and fixed it. *Finding the agent's mistakes is the skill
> the capstone actually grades.*
>
> Each entry: **what the agent produced → why it was wrong → how we caught it → the fix** (+ a lesson where useful).
>
> This is the **curated top 10** — the mistakes that mattered most (money-path correctness, deploy blockers,
> multi-agent contracts, live-cluster findings). The full chronological record (34 entries) is in
> [`agent-log-full.md`](agent-log-full.md).

---

## 1. "HA" databases that quietly used async replication → could lose a committed reservation

- **Produced:** `databases.yaml` marked the money-path databases "HA" with `instances: 2`, using CloudNativePG's
  **default asynchronous** replication.
- **Why wrong:** with async replication a primary failover can lose the last committed transactions. For
  inventory that breaks the exact invariant we claim to protect — a committed reservation could vanish on
  failover and the seat get sold twice. More instances *looked* safer, but the consistency guarantee wasn't
  actually implemented. (The atomic conditional UPDATE protects against concurrency, not against losing committed
  state.)
- **How caught:** design review against our own PACELC statement — we asked "what does a failover do to a
  committed reservation?" and the honest answer was "it can disappear".
- **Fix:** `inventory-db` → **synchronous** replication (RPO = 0; writes block if the standby is gone —
  consistency over availability, as designed). `orders-db` → synchronous `preferred` (RPO = 0 when healthy,
  degrades to async instead of blocking intake).

## 2. A JPA quirk silently dropped a state change → double restock

- **Produced:** `InventoryService.release()` set a reservation to `RELEASED` (via Hibernate dirty checking), then
  called the bulk `restock()`. That bulk update had `@Modifying(clearAutomatically = true)`, which **wiped the
  pending status change before it was ever saved**.
- **Why wrong:** the row stayed `RESERVED`, so a second `release()` restocked the seats **again** — phantom
  availability, oversell risk. Every piece looked correct in isolation; the bug was the *ordering* between dirty
  checking and context clearing, and only the idempotency test exposed it (expected 10 seats, got 14).
- **How caught:** the idempotent-replay test written alongside the code. This is why idempotency tests are
  non-negotiable on the money path.
- **Fix:** flush the status change **before** the bulk update (`flushAutomatically = true` + explicit `save()`);
  the sweep now persists all transitions before the first restock.

## 3. The restock path had no concurrency guard → oversell with 2 replicas

- **Produced:** never-oversell was protected on the **reserve** side (atomic conditional decrement) but the
  **restock** side was left unguarded: `confirm`/`release`/`expireOverdue` did a read-status-then-write with no
  `@Version` on `Reservation`.
- **Why wrong:** inventory runs 2 replicas with no leader election, so two reconcilers (or a late `confirm`
  racing the sweep) can both read the same expired hold, both flip it to EXPIRED, and **both restock** (+qty
  twice). Restock is additive, so it doesn't self-correct — the next reserve then oversells.
- **How caught:** a read-only audit flagged it; we confirmed it on the source and **proved it with a failing
  test** (8 concurrent `expireOverdue`/`confirm` on one hold, asserting a single restock).
- **Fix:** `@Version` on `Reservation` (+ migration). A stale-version loser now throws and rolls back **before**
  restocking; a lost race becomes a clean re-read of the final state, not a 5xx.

## 4. First resilience cut: the circuit-breaker fallback hid permanent faults

- **Produced (Phase 2):** the first circuit-breaker + recovery-sweep implementation mapped **every** Payments
  exception to an "unavailable → retry" fallback, swept all parked orders in one try/catch, and shipped no test
  for the `@Version` concurrency it relied on.
- **Why wrong (found by an adversarial multi-agent review of the diff):**
  1. a deterministic 4xx (a permanent client error) was treated as "temporarily unavailable" → retried forever;
  2. on a long outage the recovery sweep could **re-charge** an order whose inventory hold had already expired →
     a charge with no refund;
  3. one failing order in a batch aborted the whole sweep pass;
  4. the load-bearing `@Version` had zero test coverage.
- **How caught:** four parallel reviewer agents over the diff; the real findings were verified against the source
  and each pinned by a new test.
- **Fix:** map a 4xx to a terminal `DECLINED`; bound the park by age and never charge against an expired hold;
  per-order isolation in the sweep; an 8-thread concurrency test. Orders suite 15 → 20 tests, all green.

## 5. Compensation design that only *observed* a money leak instead of closing it

- **Produced (Phase 2):** the first refund/void design voided the authorization on an expired hold, then
  **always** rejected — bumping a "charge without refund" counter when the void failed.
- **Why wrong (caught by a design review *before* coding):** on a sustained Payments outage the void fast-fails,
  and `reject` is terminal, so the charge was **never reversed** — only counted. "Money-observable" is not
  "money-safe". Two narrower crash windows had the same shape.
- **How caught:** three parallel reviewer agents over the design returned "sound with fixes"; the leak windows
  were verified against the source and fixed before any code was written.
- **Fix:** a failed void now **parks and retries** the void until it succeeds (bounded), instead of rejecting;
  the expiry path attempts a best-effort void first; a `VOIDED` replay finishes the rejection cleanly. Each case
  pinned by a test.

## 6. A "simple" merge shipped four regressions

- **Produced (Phase 3):** a merge of parallel branches, with green-but-trivial CI, silently introduced four
  defects: (1) it reverted the working ingress domain back to a placeholder → TLS never issued; (2) it added a
  **duplicate** `letsencrypt-prod` ClusterIssuer with a different email; (3) it broke the CI build for every real
  change (invalid JSON in the build matrix → the run died in ~12 s before building anything); (4) version-pin and
  doc drift.
- **Why wrong:** a merge is not a no-op — resolving a `values.yaml` conflict toward the stale side undoes a
  committed fix. And CI that is "green" only because the build path never actually ran proves nothing.
- **How caught:** a read-only re-audit of both repos after the merge (branch diff + CI run history + tracing the
  `fromJSON` failure) — **not** by CI.
- **Fix:** pass the change list via an env var (valid JSON); consolidate to one ClusterIssuer with the real
  email; correct the domain and the pin/doc drift; re-apply the Phase-2 resilience that the merge had left out.

## 7. Three agents built both ends of a Kafka contract with no shared schema

- **Produced (async cutover):** the sync→async money path was built by **three agents in parallel** (Orders,
  Inventory, Payments). Each service keeps its own copy of the event payloads (deliberate no-shared-module
  choice), so the producer and consumer of every topic were written by different agents who couldn't see each
  other's code.
- **Why that's the risk:** the contract is held together only by matching strings — topic names, JSON fields, and
  status literals (`"RESERVED"`, `"SOLD_OUT"`, …). Any drift (`"SOLDOUT"` vs `"SOLD_OUT"`, `state` vs `status`)
  would compile, pass every in-process test (listeners are off in tests, so nothing crosses the wire), and only
  fail **silently at runtime** — a reply that never matches, a saga that wedges.
- **How caught / prevented:** (1) the exact contract (topic + field + status spelling) was **pinned up front** in
  each agent's brief, not left to each agent to invent; (2) after all three went green, the seam was verified
  against the real source — a sweep of every `Topics.kt` and status literal, checked to exactly match the topic
  set in `kafka-topics.yaml`.
- **Outcome:** no drift. **Lesson:** when agents build opposite ends of an untyped contract in parallel, fix the
  contract before fan-out and re-verify at the seam after — a per-service green build is necessary but not
  sufficient.

## 8. Subagents *invented* merge conflicts that didn't exist

- **Produced:** parallel `Explore` subagents reported a "collision map" claiming a critical conflict on a
  migration baseline and version-number clashes with the `dev` branch.
- **Why wrong:** none of it was real. `dev` only **added** new migrations (which stack additively); it never
  touched the baselines. The subagents reasoned over the *shape of the diff* instead of an actual merge.
- **How caught:** running `git merge-tree` (an authoritative dry-run merge) before choosing a strategy — it
  returned the real conflict set: 20 files, **zero** migration conflicts.
- **Fix / lesson:** plan against the tool's real output, not the agent's narrative. For merges, `git merge-tree`
  is the source of truth — the agent's "merge analysis" is just speculation over diffs.

## 9. Tracing dependencies were on the classpath but completely inert

- **Produced (Phase 4):** all services had the tracing dependencies and properties for weeks, and the roadmap
  said "the apps just need to export spans". An agent assumed deps + properties were enough.
- **Why wrong:** in **Spring Boot 4** the tracing auto-configuration moved to a dedicated module
  (`spring-boot-micrometer-tracing-opentelemetry`). Without it, **no tracer/exporter bean is created** — the deps
  and properties were a silent no-op: zero spans, no error anywhere.
- **How caught:** a test that injects `Tracer` failed with "no qualifying bean"; a classpath check confirmed no
  Boot tracing module was present — so tracing didn't exist in production either.
- **Fix:** add the module to all six services; verified by the persisted `traceparent` in the outbox row.
  **Lesson:** "dependency on the classpath + property set" ≠ "feature active" — major upgrades relocate
  auto-configurations. Prove it with a positive signal (an injected bean, a visible span), never the absence of
  errors.

## 10. The first live AKS canary aborted on a NaN false positive

- **Produced (Phase 5):** the first template-change rollout on AKS with analysis enabled aborted at step 0 —
  weights back to 100/0 with zero human action (the mechanism proven live), but the failed gate was a **false
  positive**.
- **Why wrong:** the success-rate query guarded the no-traffic case with `or vector(1)`, which only fires on an
  **empty** result. The canary had served a few requests, so its series existed; when the smoke token expired
  (401s under `uri="UNKNOWN"`, outside the query) the 2-minute window went `0/0 = NaN`, and `NaN ≥ 0.99` is false
  → 4 failures → abort.
- **How caught:** the abort itself, then reading the AnalysisRun measurements (Failed on a healthy canary).
- **Fix:** `isNaN(...) || <slo test>` in every check — a no-traffic window now means "no evidence of failure".
  **Lesson:** PromQL has **two** "no data" shapes (empty vector *and* NaN); a gate must handle both. Written up in
  full as [`postmortem.md`](postmortem.md).

---

_Add new caught mistakes to [`agent-log-full.md`](agent-log-full.md) as they happen; promote the most
instructive ones here._
