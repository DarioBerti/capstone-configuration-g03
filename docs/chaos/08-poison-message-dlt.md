# Chaos 08 — Poison message → DLT (the partition never blocks)

**Proves (Pillar C):** a malformed message can't wedge the pipeline. It is retried a *bounded* number of times,
then quarantined in a per-service dead-letter topic, and the partition keeps moving. This is the async mechanism
that **replaced the retired circuit breaker**.

**Run:** 2026-07-05, live on AKS. Cheapest experiment — no Chaos Mesh, one produced message. *Config adjustment: none.*

## Steady state (before)
- `inventory-dlt` depth: **0**
- inventory: **2/2 Running, 0 restarts**

## The one fault injected
Produced a non-JSON record `this-is-not-json` onto the **`reserve-seats`** topic (the Inventory command topic):
```bash
echo 'this-is-not-json' | kubectl -n kafka exec -i eurotransit-dual-role-0 -- \
  bin/kafka-console-producer.sh --bootstrap-server eurotransit-kafka-bootstrap.kafka.svc:9092 --topic reserve-seats
```

## What we observed
1. **Bounded retry, no storm.** Inventory's listener failed to deserialize → `DefaultErrorHandler` retried
   3 × 500 ms, then gave up (not an infinite retry).
2. **Quarantined in the DLT.** The record was routed to **`inventory-dlt`** (depth **0 → 1**) and the offset was
   committed. The DLT message carries the diagnostics:
   - `kafka_dlt-original-topic: reserve-seats`
   - `kafka_dlt-exception-fqcn: org.springframework.kafka.listener.ListenerExecutionFailedException`
   - `kafka_dlt-exception-message: Listener method '…InventoryCommandListeners.onReserveSeats…'`
   - value: `this-is-not-json`
3. **No crash-loop.** inventory stayed **2/2 Running, 0 restarts**.
4. **Partition NOT head-of-line blocked.** A valid booking placed **right after** the poison
   (`FR9612-20260629`) reached **CONFIRMED** — proof the consumer moved past the poison immediately.

## Verdict
✅ **PASS.** The poison was isolated in the per-service DLT after exactly the bounded retries, the offset was
committed, the consumer stayed healthy, and the very next order confirmed. Hypothesis held; nothing changed.

## For the oral (one breath)
> "A bad message can't take us down. We retry it a bounded number of times, then park it in a per-service
> dead-letter topic and commit the offset, so the partition isn't blocked — the next order confirms normally.
> That's our async replacement for the circuit breaker."

*Upgrade path (Phase-2 open decision) if head-of-line blocking ever matters at scale: non-blocking `@RetryableTopic`.*
