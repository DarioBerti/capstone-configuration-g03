# Experiment 03 — Node / AZ-style disruption

**Maps to:** capstone chaos #3 · already partly validated live: see `fase2-6-k8s-validation.md`
(PDB + topology-spread checked on AKS; a topology-spread issue was found and resolved).

- **Steady state (SLIs):** intake success-rate ≥ 99% with ≥ 2 replicas of each critical-path service Ready,
  spread across nodes.
- **Hypothesis:** draining/killing one node does **not** take the critical path down: PodDisruptionBudgets
  (`minAvailable: 1`) + `topologySpreadConstraints` keep ≥ 1 replica of orders/inventory/payments Ready, so
  checkout stays within SLO during the disruption.
- **Blast radius / one variable:** one node drained (voluntary) or killed (involuntary).
- **Method:** Chaos Mesh node disruption (or `kubectl drain`) on one node under steady load. NOTE (cluster
  reality): the AKS pool is 3× B2s_v2 = 6 vCPU fully booked, so an **involuntary** node-kill can leave some
  pods `Pending` (documented quota finding) — for this demo prefer a **drain** (PDB-governed) or temporarily
  shrink a non-critical service. Manifest: `platform/chaos-mesh/03-node-disruption.yaml`.

## Observation
<pods rescheduled within PDB; orders RED panel stays within SLO; which pods (if any) went Pending — screenshots>

## Conclusion
- Hypothesis held? <yes/no>
- What we changed if it didn't: <...>
