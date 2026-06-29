# Experiment 05 — CloudNativePG primary failover

**Maps to:** capstone chaos #5 · feature: synchronous replication (inventory-db/orders-db) → RPO = 0.

- **Steady state (SLIs):** intake success-rate ≥ 99%; inventory-db has 1 primary + 2 synchronous standbys
  Ready; never-oversell invariant holds.
- **Hypothesis:** killing the CloudNativePG **primary** of inventory-db causes a brief write stall while CNPG
  promotes a standby, but **no committed reservation is lost** (synchronous replication, `dataDurability:
  required` → RPO = 0), so "never oversell" still holds and checkout recovers within the stated **RTO ≤ 60 s**.
- **Blast radius / one variable:** delete/kill the primary pod of `inventory-db` only.
- **Method:** `kubectl delete pod <inventory-db-primary>` (or Chaos Mesh `PodChaos`) under steady reservation
  load; measure time-to-recovery of the intake success-rate SLI. Manifest: `platform/chaos-mesh/05-pg-failover.yaml`.

## Observation
<`kubectl cnpg status inventory-db`: promotion + sync standbys; intake success-rate dip + recovery time vs the
60 s RTO; verify post-failover that available seats == pre-failover committed state (no lost reservation) — screenshots>

## Conclusion
- Hypothesis held? <yes/no>  (RPO = 0? recovery ≤ RTO?)
- What we changed if it didn't: <...>
