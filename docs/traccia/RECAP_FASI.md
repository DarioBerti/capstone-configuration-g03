# EuroTransit — Recap Fasi 1-4 (cosa abbiamo fatto e come)

Recap operativo per il team **e** traccia per l'orale (la domanda tipica: *"che approccio implementativo avete seguito?"*).
Per lo **stato/avanzamento** vedi `FASI_PROGETTO.md`; per le **12 decisioni con rationale** vedi `docs/design.md`; gli SLI/SLO sono in `docs/slo.md`. Qui sta il "cosa + come + perché", in forma compatta.

**Sistema:** EuroTransit, marketplace di biglietti, 5 microservizi Kotlin 2.2.21 / Spring Boot 4.0.3 / JDK 21
(`catalog`, `orders`, `inventory`, `payments`, `notifications`; in arrivo `users` col rework). Il voto guarda il
**comportamento operativo sotto guasto parziale**, non le feature. Due repo in modello **GitOps**: `application`
(codice) + `configuration` (stato desiderato, riconciliato da Argo CD).

**Filo conduttore (cross-cutting, ottimo per l'orale):**
- **Idempotenza ovunque** sul money path (vincoli `UNIQUE`, UPDATE condizionali) → l'at-least-once di Kafka è sicuro.
- **Contenere il guasto, non propagarlo**: il fallimento controllato (breaker aperto, 429, bulkhead pieno) è il
  sistema che *funziona*, non che fallisce → non deve mai influenzare readiness/health.
- **GitOps come unica verità**: nessuno tocca il cluster a mano; si cambia Git e Argo allinea.
- **Osservabilità guidata dai sintomi**: si misura/allarma su ciò che l'utente vede (SLO), non sulle risorse.

---

## Fase 1 — Core money path
**Cosa:** tutta la logica di dominio dei 5 servizi, con i test verdi.
**Come / decisioni chiave:**
- **Inventory** (risorsa contesa): "never oversell" garantito da un **UPDATE atomico condizionale**
  (`UPDATE ... SET available = available - :qty WHERE product_id = :id AND available >= :qty`) — niente lock
  applicativi; o la riga si decrementa o non si tocca. Prenotazione con state machine + idempotenza via
  `UNIQUE(order_id, product_id)` (una `reserve` rid-consegnata = no-op). Reconciler a coroutine per gli scaduti.
- **Payments**: `authorize` **strettamente idempotente** (`UNIQUE(order_id)` = niente doppio addebito), PSP mock
  deterministico.
- **Orders** (orchestratore): **outbox transazionale** (l'evento si committa nella stessa transazione del cambio
  di stato, poi un relay lo pubblica → niente "scrittura persa") + **saga** orchestrata reserve→authorize→confirm
  con compensazioni e ripresa da crash.
- **Catalog**: read API pubblica; **Notifications**: consumer fully-async (degradazione controllata, può stare giù).
- **Layout**: layer-folder (controller/service/repository/entities/dto), DB-per-servizio. Test su H2; profilo
  `postgres`/`cluster` per il cluster reale. Resilience4j verificato funzionante su Boot 4.

## Fase 2 — Resilienza applicativa (Pilastro C)
**Cosa:** rendere il sistema capace di **contenere** il guasto su `Orders → Payments/Inventory`.
**Come / decisioni chiave:**
- **Circuit breaker + retry + bulkhead** applicati **programmaticamente** via i registry Resilience4j (NON via
  `@annotation`), perché su Spring Boot 4 l'AOP potrebbe non agganciare l'aspect (vedi agent-log). Composizione
  `Retry(CircuitBreaker(Bulkhead(call)))`: bulkhead separato per dipendenza (un Payments lento non esaurisce i
  permessi di Inventory), retry solo su fault di trasporto (mai su 4xx/esiti business), con backoff+jitter.
- **Fallback `PAYMENT_PENDING`**: a breaker aperto l'ordine non viene rifiutato né resta appeso → parcheggiato, poi
  un **recovery sweeper** lo drena quando Payments torna (o lo rigetta `RESERVATION_EXPIRED` entro il TTL del hold,
  così non si addebita mai una carta per un posto già restituito).
- **Backpressure / load shedding**: la POST `/api/orders` è **rate-limited al solo edge** → in sovraccarico
  risponde **429 + Retry-After** invece di accodare fino al collasso (le chiamate interne del saga NON usano 429).
- **Compensazione refund/void** su Payments per il caso prenotazione scaduta.
- **Principio**: breaker/limiter NON influenzano readiness (un breaker aperto è il sistema che lavora).

## Fase 3 — Piattaforma sul cluster reale (GitOps)
**Cosa:** il sistema gira davvero su AKS (`lab_g03_cluster`, 3× B2s_v2), riconciliato da Argo CD.
**Come / decisioni chiave:**
- **Modello a 2 repo**: la CI (application) builda+testa+pusha le immagini su ACR e **bumpa solo il tag** in
  `configuration`; Argo CD riconcilia `main`. Drift dimostrato: **selfHeal** (scale manuale → rientra) + **prune**
  (delete manuale → ricreato). La CI **non** ha mai credenziali del cluster; i secret in Git solo come SealedSecret.
- **Helm chart** con `values.yaml` come "pannello di controllo": un loop genera Deployment/Service per ogni servizio;
  flag come `criticalPath`, `hpa.enabled`, `secured`, `usesKafka` pilotano PDB/topology-spread/HPA/env.
- **Dati**: **CloudNativePG** con replica **sincrona** dove serve l'invariante — `inventory-db` (3 istanze,
  `dataDurability=required` → RPO=0, consistenza sopra disponibilità) e `orders-db` (2 ist., `preferred`). Secret DB
  generati dall'operatore (mai in Git). **Strimzi** per Kafka. **cert-manager** + Let's Encrypt (TLS prod su sslip.io).
- **Probe**: readiness = "posso servire ORA" (include il DB), liveness = solo il processo (mai un downstream, per non
  innescare restart-storm su un blip).

## Fase 4 — Observability (Pilastro D)
**Cosa:** metriche, SLO, dashboard, log e tracing che **guidano le decisioni**.
**Come / decisioni chiave:**
- **Metriche**: Micrometer → Prometheus via **ServiceMonitor** per servizio (uno per ogni entry di `services`,
  scrape di `/actuator/prometheus`). Gestite come stato desiderato nel chart (riconciliate da Argo).
- **SLO del checkout** in una `PrometheusRule`: recording rule del rapporto errori dell'intake `POST /api/orders`
  su 4 finestre + **alert burn-rate multi-finestra** (fast 1h/5m ×14.4, slow 6h/30m ×6) + alert p99 sull'ack.
  Costruita sulla metrica **standard** `http_server_requests_seconds*` (non su metriche di dominio) → **sopravvive
  al rework**. Un **429 NON conta come errore** (load shedding è comportamento voluto).
- **Alert solo symptom-based**: si paga (page) solo su error-budget burn / latenza utente; **mai** su CPU/memoria
  o stato di breaker/limiter (quelli stanno sulle dashboard come diagnostica).
- **Dashboard as-code** (ConfigMap caricate dalla sidecar Grafana): **RED** per servizio + **Runtime/golden-signals**
  JVM; **USE** infra dalle dashboard native di kube-prometheus; Kafka-lag e CNPG pronte ma gated finché non si
  abilitano gli exporter (niente pannelli vuoti).
- **Log strutturati** ECS JSON su stdout (profilo cluster), con traceId/spanId per correlare log↔trace.
- **Tracing**: app strumentate (Micrometer Tracing + OTLP), gateway **OpenTelemetry Collector → Tempo** in Grafana.
- **Validazione**: il core (metriche + SLO + alert + dashboard) è stato **verificato live sul cluster AKS** via
  GitOps; la pipeline di tracing è stata montata e provata su kind.

### Aperti / TODO (a valle della Fase 4)
- **Tracing — traccia distribuita live**: la pipeline (OTel→Tempo→Grafana) è sana, ma le app (build pre-rework) non
  esportano ancora span pur avendo dipendenze+config corrette → fix del wiring trace-export su Boot 4, **lato
  backend, su `dev`** (Riccardo). La traccia live si cattura lì (utile anche per la demo Fase 6).
- **Vincolo di capacità noto**: 3× B2s_v2 (6 vCPU) sono saturi di CPU-*requests* con observability completa → su
  AKS non stanno insieme HA al completo + tracing/chaos. Si gira su kind oppure si alza temporaneamente il node pool.
- **Chaos engineering** (i 5 esperimenti) è **Fase 6**, non 4.
