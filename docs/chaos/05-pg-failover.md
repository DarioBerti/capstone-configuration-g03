# Chaos 05 — CloudNativePG primary failover (RPO=0 + the CDC resumes)

**Proves (Pillar B + A):** synchronous replication on `inventory-db` means a primary loss costs a brief **write**
stall but **loses no committed reservation** (RPO=0), never-oversell holds, and — new with the async cutover —
the **Debezium CDC resumes** on the new primary without human action.

**Run:** 2026-07-06, live on AKS, Chaos Mesh `PodChaos` on the primary. *Config adjustment: `inventory-db` runs
**2 instances** (primary + **1** sync standby) after the Part-2 disk decision — not 3. So a failover leaves the
new primary with **no standby** until the killed pod rejoins → the write stall is bounded by that rejoin, the
deliberate consistency-over-availability price (PACELC PC/EC).*

## Steady state (before)
- `inventory-db`: **2/2** — `inventory-db-3` **primary**, `inventory-db-1` sync standby (`dataDurability: required`)
- FR9612 `available`: **71** · Debezium connectors RUNNING

## The one fault injected
```bash
kubectl apply -f platform/chaos-mesh/05-pg-failover.yaml   # PodChaos pod-kill, mode: one, cnpg.io/cluster=inventory-db, role=primary
```
First we **committed a reservation** (booked 1 seat → CONFIRMED, `available` 71 → **70**), then killed the primary.

## What we observed (promotion timeline)
| t | state |
|---|---|
| kill | primary `inventory-db-3` deleted |
| ~12 s | **standby `inventory-db-1` promoted to primary** |
| ~12–66 s | cluster at **1/2** — only the new primary, **no standby** → writes block (sync `required`) |
| ~66 s | `inventory-db-3` restarted and **rejoined as standby** → **2/2** restored |

**RPO=0 confirmed:** after the failover `available` was **still 70** = exactly the committed pre-failover state.
The committed reservation **survived** (the commit had already reached the sync standby before the kill) — **no
lost reservation, no oversell**. Reads (browse) were unaffected throughout.
**CDC resumed:** all three connectors returned **READY=True** — the PG16 logical slot was recreated on the new
primary (`-rw` re-points there). A **post-failover booking reached CONFIRMED** (`available` 70 → 69).

## Verdict
✅ **PASS.** RPO=0 (committed reservation preserved), never-oversell held, CDC self-healed, money path worked
after recovery. **Write-availability RTO ≈ 66 s** — bounded by the standby rejoining (the 2-instance tradeoff:
no spare standby, so writes block a little longer than a 3-instance cluster would). Reads never stalled.
Hypothesis held; nothing changed.

*Prod-grade next step (decided NO for now): PG17 failover slots would raise the CDC bar from "self-heals, only a
best-effort notification can be lost in the gap" to "zero missed events". Re-run this experiment after that upgrade.*
