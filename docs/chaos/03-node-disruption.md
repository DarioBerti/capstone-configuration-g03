# Chaos 03 — Node disruption (PDBs + spread keep the money path up)

**Proves (Pillar C, K8s level):** draining a node does **not** take the money path down — PodDisruptionBudgets +
topology spread keep ≥ 1 replica of every critical service Ready, and the PriorityClasses make the cluster shed
the *right* pods under the squeeze. It also surfaces an honest capacity limit of the 3-node student pool.

**Run:** 2026-07-06, live on AKS, `kubectl drain` (voluntary disruption). *Config-critical adjustment: the 3 Kafka
brokers were co-located **2 on node `m`, 1 on node `n`, 0 on node `l`**, so we drained **node `l`** — a node that
does NOT hold the broker majority — to keep the KRaft quorum. (Draining `m` would have dropped 2/3 brokers.)*

## Steady state (before)
- All critical services **2 replicas, spread across nodes**; PDBs: orders/inventory/payments `minAvailable=1`
  (allowedDisruptions=1), the CNPG `*-db-primary` PDBs `minAvailable=1` (allowedDisruptions=**0**). Pre-drain
  booking → CONFIRMED. Kafka 3/3.

## The one fault injected
```bash
kubectl drain aks-…-l --ignore-daemonsets --delete-emptydir-data --timeout=100s   # node l = 0 Kafka brokers
```

## What we observed
- **PDBs were respected.** The drain evicted the movable pods but **refused to evict the last DB replica**:
  `error evicting catalog-db-1: Cannot evict pod as it would violate the pod's disruption budget` → it waits/retries
  instead of forcing it (CNPG does a switchover, not a hard kill). Exactly the guard we want.
- **Kafka stayed intact** — brokers on `m` (×2) and `n` (×1) untouched → quorum preserved (we drained the broker-free node).
- **The money-path services never dropped to 0 Ready.** orders/inventory/payments each kept a replica on `m`/`n`
  and the evicted replicas rescheduled there (their `eurotransit-critical` priority let them preempt priority-0 pods).
- **PriorityClasses shed the right pods.** Under the squeeze onto 2 nodes, the pods that went `Pending` were the
  non-fundamental / heavy ones — `chaos-controller-manager` + `entity-operator` (priority 0), plus `keycloak`,
  `orders-db-1`, `debezium-connect-0` — **never a money-path service pod**.
- **Honest capacity finding:** a 3× B2s_v2 pool **cannot fully absorb a whole node loss** — some pods stay Pending
  until the node returns (the documented quota limit; a 4th node isn't allowed on the student sub). A booking placed
  *during* the drain didn't complete immediately (an `orders-db` replica was mid-reschedule); it recovered once the
  node came back.
- **Full recovery on `kubectl uncordon`:** Pending → **0**, cluster Healthy, **post-recovery booking → CONFIRMED**.

## Verdict
✅ **PASS on the invariant** — PDBs governed the drain, the Kafka quorum was preserved, and the money-path services
stayed available with the right (non-fundamental) pods yielding. ⚠️ **With a documented caveat**: on only 3 nodes
the cluster can't host everything on 2 during the drain, so non-critical pods go Pending and a booking placed
*exactly* during the drain may not complete until recovery. Everything self-recovered on uncordon.

## For the oral (one breath)
> "We drain a node — the one *without* the Kafka broker majority, so the quorum survives. PodDisruptionBudgets stop
> the drain from evicting the last DB replica, and topology spread + our PriorityClasses keep every money-path
> service Ready while observability and the chaos tooling yield. The honest caveat is capacity: three B2s_v2 nodes
> can't run everything on two, so some non-critical pods wait as Pending until the node returns — then it all
> recovers. On a Pay-As-You-Go pool a 4th node removes even that."
