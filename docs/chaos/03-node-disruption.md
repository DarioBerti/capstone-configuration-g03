# Experiment 03 — Node / AZ-style disruption

**Maps to:** capstone chaos #3 · already partly validated live: see `fase2-6-k8s-validation.md`
(PDB + topology-spread checked on AKS; a topology-spread issue was found and resolved).

- **Steady state (SLIs):** intake success-rate ≥ 99% with ≥ 2 replicas of each critical-path service Ready,
  spread across nodes; Kafka and Kafka Connect healthy.
- **Hypothesis:** draining/killing one node does **not** take the money path down:
  1. PodDisruptionBudgets (`minAvailable: 1`) + `topologySpreadConstraints` keep ≥ 1 replica of
     orders/inventory/payments Ready (note: orders is an **Argo Rollout** since Fase 5 — its PDB selects
     pods by the same stable labels, so the budget governs Rollout-managed pods identically);
  2. the *stateful* citizens on the drained node also ride it out: a Kafka broker (RF=3/minISR=2), a Kafka
     Connect worker (2 replicas — the connector task rebalances, see experiment 06), or a CNPG standby
     (the primary is protected by CNPG's own eviction handling; a primary drain triggers a switchover);
  3. checkout stays within SLO during the disruption.
- **Blast radius / one variable:** one node drained (voluntary) or killed (involuntary).
- **Method:** `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` under steady load. NOTE
  (cluster reality): the AKS pool is 3× B2s_v2 = 6 vCPU fully booked, so an **involuntary** node-kill can
  leave some pods `Pending` (documented quota finding) — for the demo prefer the **drain** (PDB-governed)
  or temporarily shrink a non-critical service. Manifest: `platform/chaos-mesh/03-node-disruption.yaml`
  (documents the exact commands).

## Observation (fill during the run)

- Evictions respect the PDBs (the drain *waits* rather than evicting the last replica — capture the log).
- Which stateful pods were on the node (broker/Connect/CNPG) and how each recovered.
- `checkout_intake:error_ratio:rate5m` stays within SLO; which pods (if any) went `Pending` and why.

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Money path never at 0 Ready replicas for any critical service; SLO held during the drain.
- [ ] Stateful components recovered per their own HA story (broker ISR, Connect rebalance, CNPG).
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
