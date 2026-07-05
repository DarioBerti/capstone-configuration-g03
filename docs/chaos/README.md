# Chaos-experiment reports

One report per experiment. Each follows the scientific method from the resilience lecture.
Manifests live in `platform/chaos-mesh/`.

Report template (`NN-name.md`):

```
# Experiment NN — <title>

- Steady state (SLIs): <the metrics that define "healthy", with values>
- Hypothesis: <what we expect to remain true under the failure>
- Blast radius / one failure injected: <exactly one variable>
- Method: <Chaos Mesh manifest, duration, load applied>

## Observation
<what our OWN dashboards/traces showed — screenshots/links>

## Conclusion
- Hypothesis held? yes/no
- What we changed if it didn't:
```

The suite (rewritten for the **async saga**, 2026-07-02 — the sync-era hypotheses named the retired
breaker/relay; 1–5 are the capstone minimum, 6–8 cover what the async architecture newly depends on):
1. `01-payments-latency.md` — a slow consumer never reaches the user (lag + sweeper, not errors).
2. `02-inventory-podkill.md` — never-oversell under kill + at-least-once redelivery.
3. `03-node-disruption.md` — PDBs + topology spread keep the money path available.
4. `04-kafka-partition.md` — **the central one**: a Kafka outage delays the saga, never corrupts it.
5. `05-pg-failover.md` — RPO=0 **and the Debezium CDC resumes** (slot vs failover).
6. `06-connect-worker-kill.md` — the CDC (now the only outbox→Kafka path) is HA across 2 workers.
7. `07-canary-auto-abort.md` — chaos on the canary → Argo Rollouts aborts on the SLO gates (Fase 5 ✕ 6).
8. `08-poison-message-dlt.md` — bounded retry → per-service DLT; the partition is never head-of-line blocked.

Run order for the live session: 08 (cheapest) → 02 → 01 → 06 → 04 → 05 → 03 → 07 (needs a rollout in
flight; it is also the postmortem/demo candidate). One experiment at a time, k6 load always on.
