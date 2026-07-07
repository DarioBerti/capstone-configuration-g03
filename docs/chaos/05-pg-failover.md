# Chaos 05 — Postgres primary failover

**What:** kill the `inventory-db` primary right after committing a reservation. Proves synchronous
replication gives **RPO=0** (no committed reservation lost), and that the Debezium CDC resumes on the
new primary without human action.

Run 2026-07-06 on AKS:
```bash
kubectl apply -f platform/chaos-mesh/05-pg-failover.yaml
```

## Results — ✅ PASS

- **Standby promoted in ~12s.** The seat count after failover was exactly the committed pre-failover
  state (70) — **RPO=0**: the commit had already reached the sync standby. No lost reservation, no
  oversell; reads never stalled.
- **Writes blocked ~1 minute** until the killed pod rejoined as standby (we run 2 instances, so a
  failover leaves no spare) — the deliberate consistency-over-availability price (PACELC PC/EC).
- **CDC self-healed:** the logical slot was recreated on the new primary, all connectors back to
  READY=True; a post-failover booking confirmed (70 → 69).

**Takeaway:** losing the primary costs a bounded write stall, never a committed reservation.
