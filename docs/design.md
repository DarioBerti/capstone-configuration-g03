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
  **debezium** (Kafka Connect + connector), **argo-rollouts** (progressive delivery), observability (kube-prometheus +
  OTel Collector + Tempo + dashboard), sealed-secrets, argocd, chaos-mesh, k6. Ognuno col suo `README.md`.
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
**Outbox→Kafka via Debezium CDC**: ogni servizio ha una tabella outbox; Debezium (Strimzi **Kafka Connect a 2 repliche**,
un connector per servizio) legge il WAL (CNPG `wal_level=logical` + role di replication) e pubblica sui topic. **DLT per
servizio** + retry bounded. Recoverability: un servizio che crasha riprende leggendo i topic (at-least-once + handler
idempotenti); orders non è accoppiato alla disponibilità dei downstream.

### B. Consistency under contention (Pilastro B)
Decisioni 1-3. Two-phase hold→commit → compensazioni pulite. La sync replication CNPG garantisce l'invariante anche
sotto failover (RPO=0). **Postura decisa (03/07, team):** lo slot logico di Debezium non fa failover nativo su PG16 e restiamo su PG16
(niente PG17 failover-slots): dopo un failover CNPG il connector ricrea lo slot sul nuovo primary; gli eventi del
gap si auto-riparano per il money path (sweeper → nuove righe outbox; reply ri-emesse dagli handler idempotenti) e
la perdita permanente è confinata alle notification best-effort — degradazione accettata, sorvegliata dall'alert
connector-down e verificata dal chaos #5.

### C. Resilience engineering (Pilastro C)
- **Backpressure all'edge**: `@RateLimiter` su `POST /api/orders` → **429 + Retry-After** sotto sovraccarico (rifiuto
  controllato, non coda). Solo all'edge: le chiamate interne sono su Kafka.
- **Resilienza async** (rimpiazza breaker/bulkhead/retry sincroni, ritirati col cutover): **DLT + retry bounded** sui
  consumer; **bulkhead** = consumer group separati + concurrency dei listener + pool DB separati; **backpressure** =
  consumer lag. Il **circuit breaker/retry/timeout** tornano solo attorno a un **egress esterno sincrono** (es.
  PSP reale/PayPal) — allora via `@CircuitBreaker/@Retry/@TimeLimiter` (Boot 4, `resilience4j-spring-boot4` + aspectj starter).
- **K8s**: PDB + topologySpread sui servizi `criticalPath`; probe (readiness=serve ora / liveness=processo); graceful
  shutdown; HPA (catalog/orders/users). *Prod-grade da valutare:* **KEDA** per scalare i consumer sul lag Kafka.
- **Eviction deterministica sotto node-pressure (pool studentesco, 05/07)**: il pool `3×Standard_B2s_v2` è
  memory-tight (~5.65Gi allocatable/nodo) → sotto memory pressure il kubelet sfratta *lowest-priority-first*, e senza
  priorità esplicite tutti gli app-pod stanno a 0 ⇒ vittima casuale (il "pod killed at random"). Due **PriorityClass**
  (`platform/priorityclasses.yaml`) rendono lo sfratto **deterministico**: `eurotransit-critical` (1e6 — money path
  orders/inventory/payments **+ i broker Kafka**) sfrattato per ultimo e può preemptare l'osservabilità;
  `eurotransit-platform` (1e5 — catalog/users/notifications/frontend) recuperabile, sfrattato dopo l'osservabilità;
  l'**osservabilità resta a priority 0 → prima vittima**. Entrambe ≪ `system-cluster-critical` (2e9), così
  CNI/DNS/metrics non vengono mai preemptati. Assegnate per-servizio in `_workload.tpl` via `svc.criticalPath`.
- **Right-sizing a due tier** (request ≈ RSS live — leggermente sopra, mai sotto; **nessun CPU limit**, il throttling
  danneggerebbe l'ack SLO): tier **LIGHT** `320Mi/512Mi` req/lim (catalog/users/notifications, RSS live 217-285Mi) e
  tier **CRITICAL** `448Mi/640Mi` (money path, copre il picco ~422Mi di orders, outlier della flotta); DB a
  `192Mi/512Mi`. **HPA di orders `maxReplicas` 4→3** (uno spike CPU di cold-start lo gonfiava a 4 pod senza bisogno
  duraturo). Effetto verificato live: `MemoryPressure=False`, 0 OOM, money path 200 — risolve gli sfratti casuali.
- **Caveat HA Kafka (pool disk-constrained)**: i 3 broker restano **co-locati** (nessuna anti-affinity). Lo spread
  1-broker-per-nodo è fisicamente irrealizzabile: il 3° nodo non ha slot data-disk Azure liberi (stesso **soffitto
  12-dischi** dietro la scelta inventory-db di Parte 2) ed è memory-full ⇒ un 3° broker (PVC 5Gi + 768Mi) non ci si
  schedula mai (`required` → deadlock Pending; `preferred` → comunque non piazzato). Conseguenza: perdere il nodo che
  ospita **2 broker** fa cadere il quorum KRaft → mitigazione operativa in **chaos-03: killare un nodo che NON detiene
  la maggioranza dei broker**. Un disco Pay-As-You-Go riabiliterebbe lo spread hard.

### D. Delivery + observability (Pilastro D)
- **GitOps**: Argo CD riconcilia `main`; drift self-heal + prune; secret in Git solo come **SealedSecrets**.
- **Progressive delivery** sul money path (`/api/orders`) = **Argo Rollouts** (D9 chiusa: sostituisce il peso
  manuale — quello era un "controller umano su Grafana", cioè delivery-infra fatta a mano). `orders` è un CRD
  `Rollout` (stesso pod template degli altri servizi, da `_workload.tpl`); la **policy** sta in Git, l'**esecuzione**
  è del controller: ogni bump di `image.tag` della CI diventa un rilascio progressivo **SLO-gated**.
  - **Canary** (default) = ramp 5→25→50→100 sulla `TraefikService` pesata (`orders-weighted`, pesi **patchati a
    runtime dal controller**, mai in Git) + **AnalysisRun** in background ogni 30s con 3 gate canary-scoped:
    success-rate intake ≥ target SLO, ack p99 ≤ obiettivo, **failure-rate dei listener Kafka ~0**. Analisi KO →
    **abort automatico** (peso a 0 = rollback istantaneo, nessun umano nel loop). `setCanaryScale: 1` nei primi
    step limita l'esposizione consumer del canary a 1 pod.
  - **Blue/green** (strategia alternativa, `rollout.strategy`) = preview a piena capacità, smoke-test in-cluster
    su `orders-preview`, promozione manuale = flip **atomico** del selector della Service `orders` (niente Traefik).
  - **Convivenza GitOps**: pesi/selector sono campi runtime del controller → l'app Argo CD li ignora via
    `ignoreDifferences` (managedFieldsManagers: argo-rollouts) + `RespectIgnoreDifferences` — pattern documentato
    Argo CD↔Rollouts. Il router Traefik richiede i flag `--traefik-api-group/version=traefik.io` (default ancora
    `containo.us`; supporto dal v1.7). Runbook: `platform/argo-rollouts/README.md`.
  - **⚠️ Semantica async (regola di release)**: i pod canary/preview **condividono il consumer group Kafka** con lo
    stable — il peso HTTP governa solo l'intake; le reply della saga le consuma anche il codice nuovo (la preview
    a piena capacità ne consuma ~metà PRIMA della promozione, e il flip non "disfa" ciò che ha già processato).
    Nessun tool canary-izza le partizioni: l'invariante di release è la **compatibilità di comandi/reply e
    transizioni tra versioni adiacenti** (schema forward/backward-compatible); il gate #3 dell'analysis sorveglia
    proprio il lato consumer del canary. Vale per ogni release di orders.
- **Metriche/SLO**: Micrometer→Prometheus via ServiceMonitor per servizio. SLO del checkout (`PrometheusRule`):
  **success-rate intake ≥99%/28g** e **ack p99 ≤300ms** su `http_server_requests_seconds*` (metrica standard →
  sopravvive al rework); un **429 non è errore**. Alert **burn-rate multi-finestra** (fast 1h/5m ×14.4, slow 6h/30m ×6).
  **Non si allarma** su CPU/breaker/429.
- **SLI di completamento saga (Fase 4)** — l'intake SLO vede solo la porta d'ingresso: dopo il cutover async un
  202 non significa più "ordine completato" (un ordine può stallare con zero 5xx e zero lag). Il sintomo
  user-visible è **`checkout_saga:terminal_ratio:rate30m`** = (confirmed+rejected)/placed con denominatore
  `offset 3m` (> deadline sweeper 2m): **terminal, non confirmed** — SOLD_OUT/PAYMENT_DECLINED sono esiti
  corretti della saga e non devono svegliare nessuno (il confirmed-ratio resta come pannello business). Si pagia
  su ratio < 0.99 e su **`orders_overdue_nonterminal` > 0** (gauge dello sweeper: cattura lo stallo totale anche
  a traffico zero). Contatori app: `orders_confirmed_total` / `orders_rejected_total{reason}`.
- **Ruoli dei segnali (regola: si pagia solo se serve un umano E gli utenti soffrono ADESSO):**
  | segnale | ruolo | alert |
  |---|---|---|
  | intake SLO (success-rate + ack p99) | salute porta d'ingresso | **SÌ** |
  | saga terminal-ratio + ordini stuck | ordini che non finiscono (user-visible) | **SÌ** |
  | DLT depth (`eurotransit_dlt:depth:sum`) | ordini falliti per sempre, non si auto-risana | **SÌ** |
  | CDC: connector non RUNNING / slot perso/inattivo/WAL che cresce | pipeline di pubblicazione ferma (stallo silenzioso) | **SÌ** |
  | consumer-lag (`kafka_consumergroup_lag`) | diagnostica: si auto-drena | NO — dashboard |
  | CPU/memoria/429/lag Debezium | causa o comportamento by-design | NO — dashboard |
  Sorgenti: **kafka-exporter** Strimzi (lag + offset DLT; PodMonitor `platform/strimzi/monitoring.yaml`) e
  **JMX di Connect/Debezium** (`platform/debezium/connect-metrics.yaml` + `monitoring.yaml`); slot dal
  PodMonitor CNPG (adottato via `kube-prometheus-values.yaml`, `podMonitorSelectorNilUsesHelmValues: false` —
  i PodMonitor generati da CNPG non hanno la label `release`).
- **Disciplina di cardinalità (Fase 4)**: `uri` resta templated (`/api/orders/{id}`, mai id grezzi); lag aggregato
  `by (consumergroup)`/`by (topic)`, **mai per partizione**; pannelli raggruppati per service/job, **mai per `pod`**
  (canary/HPA fanno churn dei nomi); pre-aggregazione con recording rule. **NON si droppano `pod`/`instance` sugli
  ScrapeMonitor delle app**: sono l'identità delle serie multi-replica (dropparli = serie duplicate corrotte);
  l'unica eccezione è il kafka-exporter (metriche cluster-level, `pod` droppato per evitare il churn al restart).
  Contratto label con l'analysis di Fase 5: `service`/`uri`/`result` non si toccano.
- **Doppio-scrape a riposo (Fase 5 × Fase 4)**: a riposo le Service `orders` e `orders-canary` selezionano gli
  STESSI pod stable → ogni pod è scrappato due volte (`service="orders"` e `service="orders-canary"`). I rapporti
  (error-ratio, quantili, SLO rule) sono **immuni** (numeratore e denominatore raddoppiano insieme); i pannelli di
  **rate assoluto leggerebbero 2×** → regola: i pannelli di throughput filtrano la vista stable
  (`service="orders"`, `$job` esclude `-canary|-preview`); le serie `-canary`/`-preview` si usano SOLO nelle query
  canary-scoped di `analysis.yaml`.
- **Tracing (Fase 4)**: app strumentate (Micrometer→OTLP) → **OTel Collector** (gateway) → **Tempo**. Il produttore
  degli eventi è **Debezium, non la KafkaTemplate** → l'instrumentazione in-process del producer è bypassata: il
  contesto W3C si salva come **colonna `traceparent` della riga di outbox (stessa tx)** e l'Outbox Event Router lo
  mappa a **header Kafka** (`table.fields.additional.placement: traceparent:header`); i consumer lo continuano con
  `spring.kafka.listener.observation-enabled`. **Log** ECS JSON con traceId/spanId (correlazione by-ID, Loki non
  installato — rimandata insieme agli exemplar metric↔trace, ultima miglia dopo il datasource Tempo).
- **Politica di sampling (Fase 4, la "risposta a scala")**: le app campionano al 100%; decide il **gateway** con
  `tail_sampling` (immagine **contrib**): si tengono TUTTE le tracce con errore e quelle lente (>2s end-to-end),
  il resto al 10% (tunabile in un punto solo, zero modifiche app). Log: si tengono sempre gli errori,
  level-filter sul resto. Metriche: recording rule pre-aggregate.

## 5. Note aperte / prossimi prod-grade
- **Leftover sync** (orders `oidcClient`/`extraEnv`, client `orders-svc`, secret `orders-oidc`) — **rimossi**.
- **Bulkhead/breaker**: da reintrodurre solo attorno all'egress esterno (decisione legata a **PayPal** sì/no).
- **KEDA** (autoscaling consumer su lag), **@RetryableTopic** (retry non-bloccante) — da valutare per il
  prod-grade. (~~slot-failover Debezium~~ → deciso NO il 03/07, v. §4-B.)
- **Fase 6**: chaos da riscrivere per l'async (01 payments-latency, 04 kafka-partition centrale, + kill Connect /
  failover CNPG-slot).
