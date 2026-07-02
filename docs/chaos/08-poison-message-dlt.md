# Experiment 08 — Poison message → bounded retry → DLT (partition not blocked)

**Maps to:** Pillar C's core async claim (see `capstone-dod.md`): *"a bounded consumer retry + dead-letter
topic isolates a poison message"* — the mechanism that **replaced the retired circuit breaker**. Until this
run, that claim is only asserted by unit tests; this drill proves it on the real pipeline. Cheapest
experiment of the set: no Chaos Mesh, one command.

- **Steady state (SLIs):** DLTs empty; consumer lag ~0; orders flow to terminal states.
- **Hypothesis:** publishing a malformed payload onto `reserve-seats` makes the Inventory listener throw on
  deserialization; the `DefaultErrorHandler` retries it **3 × 500 ms** (bounded — no retry storm), then the
  `DeadLetterPublishingRecoverer` routes it to **`inventory-dlt`** and the offset is committed — so the
  partition is **freed**: orders keyed to the same partition, placed right after the poison, still reach
  `CONFIRMED`. Head-of-line blocking lasts ~2 s, not forever. Nothing else is affected.
- **Blast radius / one variable:** one malformed record on one topic. (Repeat on `reservation-result` to
  drill Orders' DLT and on `authorize-payment` for Payments' — same mechanics, per-service DLT.)
- **Method:** produce the poison from inside the cluster (no Chaos Mesh needed):
  ```bash
  kubectl -n kafka run kafka-poison --rm -it --restart=Never \
    --image=quay.io/strimzi/kafka:latest-kafka-4.1.2 -- \
    bin/kafka-console-producer.sh \
      --bootstrap-server eurotransit-kafka-bootstrap.kafka.svc:9092 \
      --topic reserve-seats <<< 'this-is-not-json'
  ```
  ...while k6 keeps placing valid orders.

## Observation (fill during the run)

- Inventory log: 1 deserialization error + 3 retries, then the recoverer line; **no crash-loop**.
- The poison lands in the DLT with its diagnostic headers:
  ```bash
  kubectl -n kafka run dlt-reader --rm -it --restart=Never \
    --image=quay.io/strimzi/kafka:latest-kafka-4.1.2 -- \
    bin/kafka-console-consumer.sh \
      --bootstrap-server eurotransit-kafka-bootstrap.kafka.svc:9092 \
      --topic inventory-dlt --from-beginning --max-messages 1 \
      --property print.headers=true
  ```
  (expect `kafka_dlt-exception-*` headers naming the exception and the original topic/partition/offset.)
- Orders placed immediately after the poison still reach `CONFIRMED` (the partition moved on).
```promql
sum(rate(spring_kafka_listener_seconds_count{service="inventory", result="failure"}[2m]))  # the burst, then 0
sum by (topic) (kafka_consumergroup_lag{group="inventory"})                                 # brief blip, then ~0
```

<screenshots/links>

## Conclusion — PASS criteria
- [ ] Poison isolated in the per-service DLT after exactly the bounded retries; offset committed.
- [ ] No head-of-line blocking beyond the retry window (~2 s): subsequent orders CONFIRMED.
- [ ] Consumer healthy afterwards (no restart, no crash-loop); lag back to ~0.
- Hypothesis held? <yes/no> · What we changed if it didn't: <...>
  *(Known upgrade path if HOL blocking ever matters at scale: `@RetryableTopic` non-blocking retry — a
  Fase-2 open decision, see FASI_PROGETTO.)*
