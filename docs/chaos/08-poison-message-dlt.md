# Chaos 08 — Poison message → DLT

**What:** produce a non-JSON record (`this-is-not-json`) on the `reserve-seats` command topic. Proves a
malformed message can't wedge the pipeline: bounded retry, then quarantine in a per-service dead-letter
topic. Cheapest experiment — no Chaos Mesh needed.

Run 2026-07-05 on AKS:
```bash
echo 'this-is-not-json' | kubectl -n kafka exec -i eurotransit-dual-role-0 -- \
  bin/kafka-console-producer.sh --bootstrap-server eurotransit-kafka-bootstrap.kafka.svc:9092 --topic reserve-seats
```

## Results — ✅ PASS

- **Bounded retry:** 3 × 500ms, then the handler gave up — no infinite retry storm.
- **Quarantined:** the record landed in `inventory-dlt` (depth 0 → 1) with full diagnostics headers
  (original topic, exception, failing listener); the offset was committed.
- **No head-of-line blocking:** the very next valid booking reached **CONFIRMED** — the consumer moved
  straight past the poison. No crash-loop (0 restarts).

<<<<<<< HEAD
**Takeaway:** a bad message is parked, never propagated — the async replacement for the circuit breaker.
=======
>>>>>>> 582ea427d88224a1b23c3e8a8d7589c9f775502d
