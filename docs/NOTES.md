# Notes — what the student subscription cost us (and what a real environment would change)

This document is deliberately honest about the gap between **what we designed** and **what we could deploy**
on a free **Azure for Students** subscription. The architecture and the invariants are production-grade; several
*operational* choices are compromises forced by the substrate, not by the design. Knowing exactly which is which
is part of the exercise — so this file records, for each constraint: **what we did**, **what a real (paid /
prod) environment would let us do instead**, and **why it matters**.

## The ceiling we worked under

- **Node pool:** `3 × Standard_B2s_v2` — **6 vCPU total**, ~5.65 GiB allocatable/node, and (the binding one)
  **12 Azure managed-data-disk slots total** across the pool. **No 4th node** and **no Pay-As-You-Go** (the
  course constraint = stay on the free Students plan).
- **Cost / uptime:** the cluster is **stopped** (`az aks stop`) between sessions, so it does **not** run 24/7.
- Net effect: the pool is simultaneously **CPU-tight, memory-tight, and disk-slot-tight**. Every "HA" stack
  (3 Kafka brokers + 3 inventory DB instances + 2 orders DB + N app replicas + observability) competes for the
  same 12 disk slots and ~17 GiB of RAM, and something has to give.

## Constraint-by-constraint: what we did vs. what real infra would change

### 1. Kafka broker placement — the biggest HA compromise
- **What we did:** all **3 brokers co-located on one node** (no anti-affinity). One-broker-per-node was
  physically impossible — the 3rd node had no free data-disk slot (a broker needs a 5 GiB PVC) and was
  memory-full, so a required anti-affinity left the 3rd broker `Pending` and even `preferred` couldn't place it.
- **Real environment:** hard `podAntiAffinity`, **1 broker per node** (or a dedicated 3-node Kafka pool) → the
  KRaft quorum survives losing any single node.
- **Why it matters:** today, losing the node that holds 2 brokers drops the quorum. We mitigate this
  *operationally* (chaos-03 must kill a node that does **not** hold the broker majority) and document it as a
  known caveat — but it is a real availability gap that free capacity would simply erase.

### 2. inventory-db instances (3 → 2)
- **What we did:** `inventory-db` runs **2 instances** (primary + 1 sync standby). RPO is still 0
  (`dataDurability: required`), but if that single standby is down, **writes block**.
- **Real environment:** **3 instances** (primary + 2 sync standbys, `ANY 1 of 2`) → losing one standby does
  **not** block writes, and failover has a warm second standby ready.
- **Why it matters:** dropping to 2 was the Part-2 decision to free **one** of the 12 disk slots so the whole
  stack converges deterministically on cold start. It trades standby redundancy for schedulability — a pure
  capacity compromise, reversed instantly by more disk slots.

### 3. Deterministic eviction (PriorityClasses) + two-tier right-sizing
- **What we did:** two `PriorityClass`es make node-pressure eviction deterministic (money path evicted last,
  observability at priority 0 = first victim), and requests are right-sized to ≈ live RSS with **no CPU limit**;
  `orders` HPA is capped `maxReplicas 4→3`.
- **Real environment:** enough memory that eviction contention doesn't arise — observability co-resident with
  the app without being a sacrifice, requests set with comfortable headroom rather than shaved to live RSS, and
  HPA ceilings driven by load, not by "how many pods fit".
- **Why it matters:** the PriorityClass work is a genuinely good pattern (we'd keep it as a safety net), but on
  real infra it would be a backstop we rarely hit, not the thing standing between us and random OOM kills.

### 4. No N+1 headroom → drains leave pods Pending (chaos-03)
- **What we did:** with 3 nodes and no spare, cordoning/draining one node leaves lower-priority (priority-0 /
  heavy) pods `Pending` — an honest finding we documented in chaos-03 rather than hid.
- **Real environment:** **N+1 node capacity** (or cluster-autoscaler) so a voluntary drain reschedules
  everything with zero `Pending`.
- **Why it matters:** the money path stays up (PDBs + priorities protect it), but full-cluster resilience under
  a node loss is capacity-limited, not design-limited.

### 5. Consumer autoscaling — KEDA deferred
- **What we did:** consumers run at fixed concurrency; the only autoscaler is a CPU-HPA on the public services.
- **Real environment:** **KEDA** scaling the Kafka consumers on **consumer lag** (the correct signal), not CPU
  → the saga drains a burst faster without over-provisioning idle pods.
- **Why it matters:** on 6 vCPU there is nowhere to scale *to*, so KEDA would mostly add churn. With real cores
  it is the right prod-grade autoscaler for an async pipeline.

### 6. PG16 vs PG17 failover-slots
- **What we did:** stay on **PG16**; a logical-replication slot doesn't fail over natively, so after a CNPG
  failover Debezium recreates the slot on the new primary and the **best-effort notification** events in the gap
  can be lost (money-path events self-heal via the sweeper). We accept and alert this.
- **Real environment:** PG17 with **failover slots** (or a managed CDC offering) → the slot survives failover
  and even the best-effort-notification gap closes.
- **Why it matters:** this one is *mostly* a deliberate design call (the loss is confined and acceptable), but
  more operational freedom would let us remove even that small documented degradation.

### 7. Separate node pools / workload isolation
- **What we did:** one pool runs everything — system add-ons, the money path, observability, Kafka, and Chaos
  Mesh all share 3 nodes (Chaos Mesh's control plane is even scaled to 0 between experiments to save memory).
- **Real environment:** dedicated node pools (system / money-path / data / observability) so a noisy neighbour
  or a chaos experiment can't compete with the money path for RAM, and the observability stack isn't a
  memory-pressure liability.
- **Why it matters:** most of our "why is this pod Pending / evicted" operational noise comes from co-tenancy on
  a tiny shared pool.

### 8. Always-on cluster → real SLO/error-budget windows
- **What we did:** the cluster is stopped between sessions, so the **28-day** burn-rate SLO windows and the
  canary AnalysisRun history only ever see short, bursty live windows; cold start is a turbulent ~10–15 min
  (apps CrashLoop until CNPG accepts connections).
- **Real environment:** an always-on cluster → the multi-window burn-rate alerts and error budgets accumulate
  real longitudinal data, canary analysis has a stable baseline, and there is no repeated cold-start storm.
- **Why it matters:** our SLO machinery is correct and wired; it just never gets to observe a realistic
  steady-state window on a cluster that lives in bursts.

## What we would NOT change (these are not compromises)

The following are production-grade regardless of budget, and we would ship them unchanged: the **async
command/reply saga**, the **transactional outbox + Debezium CDC** publishing model, **never-oversell** (atomic
conditional decrement + DB `CHECK`), **exactly-once via idempotency keys**, the **PACELC-as-configuration**
replication posture, **GitOps with Argo CD** (prune + self-heal), **progressive delivery** (SLO-gated canary +
blue/green), **symptom/burn-rate SLO alerting**, **cross-Kafka distributed tracing**, and **secrets only as
SealedSecrets**. The substrate limited *how much* redundancy and headroom we could deploy — not *how* the system
is designed to behave under failure.
</content>
