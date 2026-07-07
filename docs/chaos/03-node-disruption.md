# Chaos 03 — Node drain

**What:** drain one of the 3 nodes — deliberately the one *without* the Kafka broker majority, so the
KRaft quorum survives. Proves PDBs + topology spread + PriorityClasses keep the money path available
through a voluntary node loss.

Run 2026-07-06 on AKS:
```bash
kubectl drain <node-l> --ignore-daemonsets --delete-emptydir-data --timeout=100s
```

## Results — ✅ PASS (with a documented capacity caveat)

- **PDBs governed the drain**: it refused to evict the last DB replica ("would violate the pod's
  disruption budget") and waited instead of forcing it.
- **Money-path services never dropped to 0 Ready**; evicted replicas rescheduled on the other nodes,
  preempting priority-0 pods.
- **The right pods yielded**: what went Pending was chaos tooling, entity-operator, keycloak — never a
  money-path pod. Kafka quorum untouched.
- **Caveat:** 3 small nodes can't host everything on 2 — some non-critical pods stayed Pending until
  `uncordon`, and a booking placed exactly during the drain completed only after recovery. Everything
  self-recovered; post-recovery booking → CONFIRMED.

**Takeaway:** the invariant held (money path up, quorum safe); the limit is capacity of the student
pool, not the design — a 4th node would remove the caveat.
