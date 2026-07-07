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

<<<<<<< HEAD
**Takeaway:** losing the primary costs a bounded write stall, never a committed reservation.
=======
## Verdict
✅ **PASS.** RPO=0 (committed reservation preserved), never-oversell held, CDC self-healed, money path worked
after recovery. **Write-availability RTO ≈ 66 s** — bounded by the standby rejoining (the 2-instance tradeoff:
no spare standby, so writes block a little longer than a 3-instance cluster would). Reads never stalled.
Hypothesis held; nothing changed.

*Prod-grade next step (decided NO for now): PG17 failover slots would raise the CDC bar from "self-heals, only a
best-effort notification can be lost in the gap" to "zero missed events". Re-run this experiment after that upgrade.*
>>>>>>> 582ea427d88224a1b23c3e8a8d7589c9f775502d
