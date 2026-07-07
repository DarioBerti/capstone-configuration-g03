# Chaos experiments

One report per experiment; manifests in `platform/chaos-mesh/`. All run live on AKS (2026-07-05/06),
all **PASS**. Run order for a live session: 08 (cheapest) → 02 → 01 → 06 → 04 → 05 → 03 → 07.

> **Before a Chaos Mesh session:** the control plane is scaled to 0 by default (memory). Scale it up
> first, back to 0 after (08 doesn't need it):
> ```bash
> kubectl -n chaos-mesh scale deploy chaos-controller-manager --replicas=1   # before (wait ~30s)
> kubectl -n chaos-mesh scale deploy chaos-controller-manager --replicas=0   # after
> ```

**01 — Latency into Payments.** 3s of network delay between Payments and Kafka. The user never sees it:
intake stays at ~0.2s, the order just confirms later (21s instead of 5s). A slow downstream becomes saga
latency, not an error — the async replacement for the circuit breaker.

**02 — Inventory pod-kill mid-reservation.** Kill one of two Inventory replicas while a booking is in
flight. The booking still confirms and the seat count is exact (75 → 74): the unacked command is
redelivered to the survivor, and idempotency makes the replay harmless. Never-oversell held.

**03 — Node drain.** Drain a node (the one without the Kafka broker majority). PDBs refuse to evict the
last DB replica, money-path services never drop to 0 Ready, and PriorityClasses shed only non-critical
pods. Honest caveat: 3 small nodes can't host everything on 2, so some pods stay Pending until the node
returns — then full recovery.

**04 — Kafka partition (the central one).** Cut Orders off from Kafka for ~3 minutes. The intake keeps
accepting durably (the row is committed in Postgres), the saga freezes but corrupts nothing; on heal the
backlog drains and the order confirms in seconds. A Kafka outage is a delay, never a loss.

**05 — Postgres primary failover.** Kill the inventory-db primary. The standby is promoted in ~12s and
no committed reservation is lost (**RPO=0**, synchronous replication); writes block ~1 min until the
killed pod rejoins (the 2-instance consistency-over-availability tradeoff). The Debezium CDC recreates
its slot on the new primary by itself.

**06 — Kafka Connect worker kill.** Kill one of two Debezium workers — the only outbox→Kafka path. The
surviving worker keeps all connectors RUNNING, the CDC pauses seconds at most, the order confirms.
Zero loss by construction (slot position in Postgres, offsets in Kafka).

**07 — Chaos on the canary → auto-abort.** During a real release ramp at 25%, delay all canary egress by
400ms. Only the p99 gate fails (success rate stays 1.0), and after 4 bad measurements Argo Rollouts
aborts the release **on its own** — weights snap to 100% stable, which never suffered. Bonus finding:
the first injection silently did nothing (pod-label target vs ClusterIP routing) and the canary
auto-promoted twice — "chaos injected" ≠ "chaos effective".

**08 — Poison message → DLT.** Produce a non-JSON record on `reserve-seats`. Bounded retry (3×500ms),
then quarantine in `inventory-dlt` with full diagnostics; no crash-loop, and the very next order
confirms — the partition is never head-of-line blocked.
