# EuroTransit — Design & scelte implementative (config repo)

> Team-owned. Documento **unico** e canonico di design ad alto livello del sistema e del repo di
> configurazione — ogni scelta è difendibile all'orale. Si aggiorna **direttamente** quando cambia
> l'architettura (niente più file sparsi per fase). Companion: `docs/traccia/FASI_PROGETTO.md` = avanzamento
> (cosa c'è / cosa manca, per fase); `docs/agent-log.md` = errori degli agenti (gradato);
> `docs/agent-threat-model.md`, `docs/postmortem.md`, `docs/chaos/*` = artefatti dei Pilastri; i
> `platform/*/README.md` = runbook operativi per componente. Il design del **codice** sta nel repo `application`.

## 1. Sistema
Marketplace di biglietti treno, cloud-native, valutato sul **comportamento operativo sotto guasto parziale**.
6 microservizi Kotlin 2.2 / Spring Boot 4 / JDK 21 (`it.g03.<svc>`):
- **catalog** — read API pubblica (staleness-tolerant)
- **orders** — orchestratore del money path (saga **async Kafka command/reply**) + outbox transazionale
- **inventory** — risorsa contesa, prenotazione atomica (never-oversell), two-phase reserve→confirm
- **payments** — autorizzazione idempotente (no double-charge), two-phase authorize→capture; PSP **mock** dietro interfaccia
- **notifications** — fully async, degrada in modo controllato
- **users** — profili Keycloak-backed (subject del JWT)

**Modello GitOps a 2 repo:** `application` (codice; la CI builda+testa+pusha l'immagine taggata col commit SHA e
bumpa `image.tag` in `configuration`) + `configuration` (stato desiderato, riconciliato da **Argo CD** su `main`).
La CI **non tocca mai il cluster** (scrive solo il tag via PAT least-privilege).

## 2. Struttura del config repo
- `deploy/charts/eurotransit/` — Helm chart unico. `values.yaml` è il **pannello di controllo** (ogni template
  legge da lì); `values-kind.yaml` overlay locale, base/`values-prod` per AKS. `templates/` = un file per concern;
  `_workload.tpl` = definizione riusabile Deployment+Service (stable **e** canary/green da UNA sorgente).
- `platform/` — componenti installati once (non nel chart): traefik, cert-manager, cloudnativepg, strimzi (Kafka),
  **debezium** (Kafka Connect + connector), observability (kube-prometheus + OTel Collector + Tempo + dashboard),
  sealed-secrets, argocd, chaos-mesh, k6. Ognuno col suo `README.md`.
- `bootstrap/` — kind cluster; `justfile` — runbook locale.

## 3. Decisioni di design chiave (con rationale)
1. **CAP/PACELC = CP dove vive l'invariante.** `inventory-db` (e `orders-db`) in **replica sincrona CNPG**
   (`dataDurability=required` per inventory) → **RPO=0**: sotto partizione blocca la scrittura piuttosto che rischiare
   di perdere una prenotazione. `catalog`/`payments`-db single-instance (staleness-tolerant / correttezza via idempotenza).
2. **Never-oversell** = UPDATE condizionale atomico (`available >= qty`): il row-lock serializza i concorrenti, il
   perdente vede 0 righe = sold out. Nessun lock applicativo.
3. **No double-charge / exactly-once** = idempotenza con `UNIQUE(order_id)` (payments) e `UNIQUE(order_id,trip)`
   (inventory) → l'at-least-once di Kafka è sicuro (redelivery = no-op).
4. **Saga async command/reply su Kafka** (vedi §4-A) al posto di chiamate HTTP sincrone: recoverability + disaccoppiamento.
5. **Outbox transazionale + Debezium CDC** (vedi §4-A): l'evento si committa con il cambio di stato; **Debezium** legge
   l'outbox dal WAL (log-based, no polling — sostituisce il vecchio relay a thread).
6. **Resilienza sui sintomi, non sulle risorse** (§4-C/D): alert burn-rate su SLO, mai su CPU.
7. **Un template, N workload** (`_workload.tpl`): stable e canary/blue-green condividono la definizione → niente drift.

## 4. Design per pilastro
### A. Distributed & async (Pilastro A)
Money path = **saga orchestrata async**: `POST /api/orders` (202 Accepted, ack durevole) → orders emette il comando
`reserve-seats` → inventory prenota (hold) e risponde `reservation-result` (via il **suo** outbox) → orders emette
`authorize-payment` → payments autorizza e risponde `payment-result` → orders emette `confirm-seats` + `capture-payment`
→ CONFIRMED. Compensazioni: `release-seats` / `cancel-authorization`. Stato reply-driven
`PENDING→RESERVED→AUTHORIZED→CONFIRMED (+REJECTED)`; `OrderTimeoutSweeper` ri-guida gli ordini bloccati oltre la deadline.
**Outbox→Kafka via Debezium CDC**: ogni servizio ha una tabella outbox; Debezium (Strimzi **Kafka Connect a 3 repliche**,
un connector per servizio) legge il WAL (CNPG `wal_level=logical` + role di replication) e pubblica sui topic. **DLT per
servizio** + retry bounded. Recoverability: un servizio che crasha riprende leggendo i topic (at-least-once + handler
idempotenti); orders non è accoppiato alla disponibilità dei downstream.

### B. Consistency under contention (Pilastro B)
Decisioni 1-3. Two-phase hold→commit → compensazioni pulite. La sync replication CNPG garantisce l'invariante anche
sotto failover (RPO=0). **Nota aperta:** lo slot logico di Debezium non fa failover nativo su PG → dopo un failover CNPG
il CDC va ripristinato (mitigazione + verifica nel chaos #5).

### C. Resilience engineering (Pilastro C)
- **Backpressure all'edge**: `@RateLimiter` su `POST /api/orders` → **429 + Retry-After** sotto sovraccarico (rifiuto
  controllato, non coda). Solo all'edge: le chiamate interne sono su Kafka.
- **Resilienza async** (rimpiazza breaker/bulkhead/retry sincroni, ritirati col cutover): **DLT + retry bounded** sui
  consumer; **bulkhead** = consumer group separati + concurrency dei listener + pool DB separati; **backpressure** =
  consumer lag. Il **circuit breaker/retry/timeout** tornano solo attorno a un **egress esterno sincrono** (es.
  PSP reale/PayPal) — allora via `@CircuitBreaker/@Retry/@TimeLimiter` (Boot 4, `resilience4j-spring-boot4` + aspectj starter).
- **K8s**: PDB + topologySpread sui servizi `criticalPath`; probe (readiness=serve ora / liveness=processo); graceful
  shutdown; HPA (catalog/orders/users). *Prod-grade da valutare:* **KEDA** per scalare i consumer sul lag Kafka.

### D. Delivery + observability (Pilastro D)
- **GitOps**: Argo CD riconcilia `main`; drift self-heal + prune; secret in Git solo come **SealedSecrets**.
- **Progressive delivery** sul money path (`/api/orders`), GitOps-native via CRD Traefik:
  - **Canary** = `IngressRoute` → `TraefikService` pesata `{orders: 100-w, orders-canary: w}`; peso in `values.yaml`,
    promozione 5→50→100 = commit osservando le SLO, rollback = weight 0.
  - **Blue/green** = `orders-green` a piena capacità + IngressRoute 100% al colore `active` (switch atomico).
  - Mutuamente esclusivi (il chart fa `fail` se entrambi). *Valutare Argo Rollouts* per l'analisi automatica.
- **Metriche/SLO**: Micrometer→Prometheus via ServiceMonitor per servizio. SLO del checkout (`PrometheusRule`):
  **success-rate intake ≥99%/28g** e **ack p99 ≤300ms** su `http_server_requests_seconds*` (metrica standard →
  sopravvive al rework); un **429 non è errore**. Alert **burn-rate multi-finestra** (fast 1h/5m ×14.4, slow 6h/30m ×6).
  **Non si allarma** su CPU/breaker/429. Da abilitare ora che la saga è Kafka: dashboard **consumer-lag** + monitoraggio
  **CDC/Connect** (stato connector, slot).
- **Tracing**: app strumentate (Micrometer→OTLP) → **OTel Collector** (gateway) → **Tempo** (datasource Grafana);
  traceId propagato negli header Kafka per vedere l'intera pipeline. **Log** ECS JSON con traceId/spanId.

## 5. Note aperte / prossimi prod-grade
- **Leftover sync** (orders `oidcClient`/`extraEnv`, client `orders-svc`, secret `orders-oidc`) — **rimossi**.
- **Bulkhead/breaker**: da reintrodurre solo attorno all'egress esterno (decisione legata a **PayPal** sì/no).
- **KEDA** (autoscaling consumer su lag), **slot-failover Debezium**, **@RetryableTopic** (retry non-bloccante) —
  da valutare per il prod-grade.
- **Fase 6**: chaos da riscrivere per l'async (01 payments-latency, 04 kafka-partition centrale, + kill Connect /
  failover CNPG-slot).
