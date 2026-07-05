# Debezium CDC — the outbox relay

This is the **outbox relay** for the money path. The services (orders, inventory, payments) write an
`outbox_events` row in the same transaction as the business change; **Debezium** reads those rows off each
Postgres WAL via logical decoding and republishes them to Kafka. It replaces the retired in-app polling
relay (`OutboxPublisher`/`OutboxDrainer` in the app repo).

The **Outbox Event Router** SMT reproduces the exact pre-CDC wire format, so **consumers are unchanged**:

| Kafka record field | Source | Notes |
|---|---|---|
| topic | `topic` column | `route.by.field=topic` → e.g. `reserve-seats`, `payment-result` |
| key   | `aggregate_id` column | the orderId → per-order partition ordering |
| value | `payload` column | raw JSON string, `StringConverter` → byte-identical to the old producer |
| header `traceparent` | `traceparent` column | Fase 4: W3C trace context saved by the app in the outbox row (same tx); `table.fields.additional.placement=traceparent:header`. NULL column (e.g. sweeper re-drive) → no usable header, the consumer starts a fresh trace. Consumers continue it via `spring.kafka.listener.observation-enabled`. **Deploy order: the app migration adding the column must land BEFORE this connector config.** |

CDC health is scraped via `connect-metrics.yaml` (JMX rules) + `monitoring.yaml` (PodMonitor + the
`eurotransit-cdc` alerts: connector not RUNNING, metrics absent, replication slot missing/inactive/retaining
WAL — the slot alerts are the proof hook for chaos exp 05).

## Pieces

- `Dockerfile` — Strimzi Connect base + the Debezium Postgres plugin. Build + push before deploying.
- `kafka-connect.yaml` — the Connect cluster (PROD/HA, 2 replicas). `kind/kafka-connect-kind.yaml` is the laptop variant.
- `connectors/*.yaml` — one `KafkaConnector` per DB (shared by prod and kind).
- The **source side** (publication, grants, heartbeat table, `wal_level=logical`, the `debezium` role) is
  provisioned in the OTHER repo: Flyway migrations (`V*__debezium_publication.sql`) + CloudNativePG
  (`deploy/charts/eurotransit`, `databases.yaml` + `values.yaml`).

## Secrets (two namespaces — SealedSecrets are namespace-scoped)

The `debezium` DB password is needed in **both** namespaces, and the two copies MUST hold the same value:

1. **`eurotransit`** — CloudNativePG sets the `debezium` role password from a per-DB `<db>-debezium` secret.
2. **`kafka`** — the Connect cluster authenticates as `debezium` using the `debezium-db` secret (one key per DB).

### Prod — commit as SealedSecrets

```bash
# pick one strong password per DB (or reuse one); the SAME value goes into BOTH namespaces for that DB.
ORD=$(openssl rand -base64 24); INV=$(openssl rand -base64 24); PAY=$(openssl rand -base64 24)

# (1) eurotransit ns — the CNPG role password, one basic-auth secret per DB. Commit under a path the
#     eurotransit Argo app syncs, e.g. deploy/charts/eurotransit/templates/.
for db_pw in "orders-db:$ORD" "inventory-db:$INV" "payments-db:$PAY"; do
  db=${db_pw%%:*}; pw=${db_pw##*:}
  kubectl create secret generic "$db-debezium" -n eurotransit \
    --type=kubernetes.io/basic-auth --from-literal=username=debezium --from-literal=password="$pw" \
    --dry-run=client -o yaml | kubeseal --format yaml > "$db-debezium-sealedsecret.yaml"
done

# (2) kafka ns — one secret the connectors read (keys match ${file:.../debezium-db/<svc>-password}).
#     Commit under platform/debezium/ so the debezium Argo app syncs it.
kubectl create secret generic debezium-db -n kafka \
  --from-literal=orders-password="$ORD" \
  --from-literal=inventory-password="$INV" \
  --from-literal=payments-password="$PAY" \
  --dry-run=client -o yaml | kubeseal --format yaml > debezium-db-sealedsecret.yaml
```

Plaintext `*-secret.yaml` is git-ignored; only `*-sealedsecret.yaml` may be committed (see
`platform/sealed-secrets/README.md`).

### Kind — no kubeseal

Both copies are generated for you: the app chart renders the `eurotransit`-ns `<db>-debezium` secrets when
`debezium.devSecrets=true` (values-kind.yaml), and `just debezium-kind-apply` creates the `kafka`-ns
`debezium-db` secret — both from `debezium.dev.dbPassword` (`values.yaml`, default `debezium-dev-pass`).

## Deploy order (Debezium-first cutover)

Because the app image no longer contains the relay, bring Debezium up **before** (or with) the new app so
no events are stranded. Any gap in the switchover window is re-driven by the orders **timeout sweeper**
(idempotent commands), so at-least-once holds.

**Prod:** register both Argo apps (`platform/argocd/eurotransit-application.yaml`,
`platform/argocd/debezium-application.yaml`). Build + push the Connect image first
(`docker build -t labg03clusterregistry.azurecr.io/eurotransit/debezium-connect:1.0.0 platform/debezium && docker push …`).

**Kind:** after `just app-deploy` and once the DB pods are Ready (Flyway has created the publications), run
`just debezium-kind-apply`.

## Verify

```bash
kubectl -n kafka get kafkaconnect debezium-connect          # READY
kubectl -n kafka get kafkaconnector                          # all READY
# on any DB pod: slot present and lag bounded (heartbeat advancing)
kubectl -n eurotransit exec orders-db-1 -- psql -d ordersdb -c \
  "SELECT slot_name, active, pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag FROM pg_replication_slots;"
```

## PG16 caveat (failover)

A logical replication slot lives only on the primary and does **not** fail over natively on Postgres 16
(that is a PG17 feature). If `inventory-db`'s primary is killed (chaos-05), Debezium recreates the slot at
the current LSN and may miss the in-flight window; the orders timeout sweeper re-drives any stuck saga, so
correctness holds. `max_slot_wal_keep_size` (set in `databases.yaml`) caps WAL growth if a slot wedges.
