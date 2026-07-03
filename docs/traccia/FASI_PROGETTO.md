# EuroTransit — Fasi del progetto (dove siamo, cosa manca)

**Mappa di avanzamento** condivisa: a che punto siamo, cosa è fatto/verificato, cosa resta. Aggiornala quando
una fase cambia stato. Il **design + scelte implementative** (alto livello) sta in `docs/design.md`; gli errori
degli agenti (gradato) in `docs/agent-log.md`.

> **DOVE SIAMO (03/07/2026):** Fasi 0-5 **fatte e validate LIVE su AKS** (primo deploy async: money path
> CONFIRMED E2E, CDC su, tracing cross-Kafka in Tempo, ramp canary SLO-gated + abort automatico). Fase 4
> CHIUSA (incluso #8 exemplar/Tempo-datasource). Decisioni: **D9=Rollouts**, **PG17 failover-slots=NO**
> (perdita notification accettata). **Resta:** Fase 6 esecuzione (8 runbook pronti — Chaos Mesh su AKS +
> sessione live + postmortem + demo), Fase 2 ri-collocazioni (PayPal/KEDA, con Riccardo), seal dei secrets.
> Cluster AKS **fermo** salvo sessioni (sempre `az aks stop` a fine).

Legenda: ✅ fatto · 🔄 in corso · ⬜ da fare

```text
 Fase 0  Fondamenta             ✅
 Fase 1  Core money path        ✅   ← 6 servizi; saga ora ASYNC Kafka command/reply + outbox
 Fase 2  Resilienza             🔄   ← edge @RateLimiter (429) + DLT/retry async OK; breaker/bulkhead da ri-collocare
 Fase 3  Piattaforma su cluster ✅   ← verificata su AKS; + Debezium (Kafka Connect 3 repliche, CNPG logical)
 Fase 4  Observability          ✅   ← VALIDATA LIVE su AKS 03/07: lag+CDC+DLT+SLI saga+tracing cross-Kafka E2E
 Fase 5  Progressive delivery   ✅   ← Argo Rollouts VALIDATO su AKS 03/07: ramp 3 gate×19 ok + abort automatico
 Fase 6  Chaos + postmortem     🔄   ← 8 runbook async PRONTI; resta: Chaos Mesh su AKS + sessione live + demo
```

Riferimenti: `docs/design.md` (design + scelte), `capstone-application-g03/NOTE_IT.md` (strati di un servizio),
`docs/traccia/GUIDA-STRUTTURA-REPOSITORY.md` (i due repo), `docs/chaos/*` (runbook Fase 6).

---

## Fase 0 — Fondamenta ✅
Due repo GitOps (`application` + `configuration`), scheletro servizi (Kotlin 2.2 / Boot 4 / JDK 21), CI a matrice
(build+test+push, mai credenziali cluster), `justfile`, `docs/` di team (design, agent-log, threat-model).

## Fase 1 — Core money path ✅
Logica di dominio dei 6 servizi; invarianti codificate (never-oversell, no-double-charge, nessun evento perso).
- ✅ **Inventory** — UPDATE atomico condizionale (never-oversell), idempotenza, two-phase reserve→confirm.
- ✅ **Payments** — `authorize→capture` idempotente (`UNIQUE(order_id)`), PSP mock dietro interfaccia.
- ✅ **Orders** — orchestratore: **saga async Kafka command/reply** (reply-driven `PENDING→RESERVED→AUTHORIZED→CONFIRMED`)
  + **outbox transazionale** drenato via **Debezium CDC**; `OrderTimeoutSweeper` ri-guida gli ordini bloccati.
- ✅ **Catalog** (read API), **Notifications** (fully-async, degrada), **Users** (profili Keycloak).

## Fase 2 — Resilienza applicativa 🔄 (Pilastro C — ri-collocata post-async)
Col cutover async, il breaker/bulkhead/retry **sincroni** sono stati **ritirati** (non c'è più chiamata sync). Stato:
- ✅ **Backpressure edge**: `@RateLimiter` su `POST /api/orders` → **429 + Retry-After**.
- ✅ **Resilienza async**: **DLT per servizio** + retry bounded sui consumer.
- ⬜ **Da ri-collocare (decisione team):** *bulkhead* = consumer group separati + `listener.concurrency`/`max.poll.records`;
  *retry* = backoff **esponenziale + jitter** (evita retry-storm); *circuit breaker/retry/timeout* solo attorno a un
  **egress esterno sync** (es. PayPal) via `@annotation` (Boot 4, `resilience4j-spring-boot4` + aspectj starter);
  *autoscaling consumer* = **KEDA** su consumer-lag (non CPU-HPA). → dipende dalla decisione **PayPal** e da KEDA.

## Fase 3 — Piattaforma sul cluster reale ✅ (verificata su AKS)
- ✅ Traefik, cert-manager, **CloudNativePG** (sync replication inventory/orders → RPO=0), **Strimzi/Kafka**,
  Sealed Secrets, Argo CD **Synced&Healthy** (drift self-heal + prune dimostrati), TLS Let's Encrypt prod.
- ✅ **Debezium CDC** (async rework): Strimzi **Kafka Connect (3 repliche, HA)** + connector per servizio (Argo-managed) +
  CNPG in **logical replication** (`wal_level=logical` + role di replication). Sostituisce il relay a polling.
- ✅ CI → bump `image.tag` su config (mai credenziali cluster). Money-path verificato `→ CONFIRMED`.
- ✅ **DECISO (03/07): restiamo su PG16, niente failover-slots.** Lo slot logico muore col primary; il money
  path si auto-ripara (sweeper ri-emette i comandi, handler idempotenti ri-emettono le reply) e la perdita
  permanente è confinata alle **notification best-effort** — degradazione accettata e documentata (design §4-B).
  Il chaos #5 verifica esattamente questa postura + l'alert connector-down.

## Fase 4 — Observability ✅ (VALIDATA LIVE su AKS 03/07 — stack completo)
> **Validazione live 03/07** (post-merge PR #16/#17/#18 config + #10/#11 app, primo deploy async su AKS):
> money path async **CONFIRMED end-to-end** (120 CONFIRMED + 49 REJECTED=SOLD_OUT: never-oversell live, posti
> esauriti → rifiuti puliti); Debezium **3 connector RUNNING** (immagine Connect ora buildata dalla CI);
> `kafka_consumergroup_lag` (exporter), CDC (`debezium_metrics_*`), DLT depth=0, SLI saga (placed=confirmed),
> 4 gruppi di rule caricati; **traccia cross-Kafka in Tempo**: orders+inventory+notifications nella STESSA
> traccia (traceparent via outbox→Debezium header, 2 hop). Fix live committati: label `part_of` (2 rule
> respinte dal webhook), property OTLP **Boot 4** (`management.opentelemetry.tracing.export.otlp.endpoint` —
> senza, zero span esportati), gate analysis NaN-proof, Strimzi 1.0.0→**1.1.0** su AKS (Kafka 4.3.0),
> right-size memoria Keycloak (1700Mi→700Mi). V. agent-log #22-#24.
- ✅ **Metriche+SLO+alert**: kube-prometheus adotta le nostre ServiceMonitor (validato LIVE su AKS 29/06); rule
  `eurotransit-checkout-slo` (success-rate intake ≥99% + ack p99, burn-rate multi-finestra; 429 non è errore; mai su CPU).
- ✅ **Dashboard as-code** (RED per servizio + Runtime/golden-signals) caricate in Grafana.
- ✅ **Fix capacità (PR #9, verificato LIVE 30/06):** CPU requests `100m→50m` (fix di booking) → gli standby CNPG
  schedulano, observability + HA CNPG **coesistono** sui 3× B2s_v2.
- ✅ **Tracing cross-Kafka (implementato 02/07, VALIDATO live 03/07)**: il producer è **Debezium, non la
  KafkaTemplate** → il contesto W3C si persiste come colonna `traceparent` della riga outbox (stessa tx) e
  l'EventRouter lo mappa a header Kafka; consumer con `listener.observation-enabled`. Validato su AKS:
  orders+inventory+notifications nella STESSA traccia in Tempo. (Il warning #21 sul tag `result` era fondato:
  fixato col tag observation `error!="none"` — agent-log #22.)
- ✅ **Consumer-lag + DLT + CDC monitoring (02/07, branch `fase-4-observability`)**: kafka-exporter sui due CR
  Kafka + PodMonitor (`platform/strimzi/monitoring.yaml`, label `group` clonata da `consumergroup` per i
  runbook Fase 6); JMX Connect/Debezium (`platform/debezium/connect-metrics.yaml` + `monitoring.yaml`) con
  alert **connector non-RUNNING / metriche assenti / slot perso-inattivo-WAL>256Mi** (lega al chaos #5/#6);
  **DLT depth** con page `DeadLetterTopicNotEmpty`; dashboard kafka+cnpg s-commentate (adozione PodMonitor
  CNPG via `kube-prometheus-values.yaml`).
- ✅ **SLI di completamento saga (02/07)**: `checkout_saga:terminal_ratio:rate30m` (terminal, non confirmed:
  SOLD_OUT/DECLINED sono esiti corretti) + gauge `orders_overdue_nonterminal` dallo sweeper; 2 alert page
  nel gruppo `eurotransit-saga-slo` del chart; riga saga sulla dashboard RED. Contatori app su
  `fase-4-tracing` (`orders_confirmed_total`/`orders_rejected_total{reason}`).
- ✅ **Cardinalità + sampling (02/07)**: policy in design.md §4-D (uri templated, mai per-partizione/per-pod,
  doppio-scrape a riposo → pannelli throughput in vista stable; identity label NON droppate);
  `tail_sampling` sul Collector gateway (immagine contrib: errori+lenti al 100%, resto 10%).
- ✅ **Ultima miglia correlazione (#8, 03/07)**: Tempo = datasource Grafana (uid pinnato) + **exemplar**
  (Prometheus `exemplar-storage` + `exemplarTraceIdDestinations` sul datasource di default → il pallino sul
  pannello apre la traccia in Tempo) — tutto in `kube-prometheus-values.yaml`; su AKS va ri-applicato con
  l'`helm upgrade -f` (da fare all'avvio della sessione chaos, con verifica visiva del click-through).
  **Loki = non-goal documentato**: i log ECS portano già traceId/spanId → correlazione log↔trace by-id.
- ✅ **Cosmetico app chiuso (03/07)**: property OTLP rinominata al nome Boot 4 nei 6 `application.yml`
  (l'env legacy nel chart è stata rimossa: su Boot 4 non bindava nulla).

## Fase 5 — Progressive delivery ✅ (Argo Rollouts — VALIDATO LIVE SU AKS 03/07)
> **Su AKS**: migrazione Deployment→Rollout live; primo ramp reale 5→25→50→100 **gated dall'analysis su
> Prometheus** (3 gate × 19 misurazioni Successful sotto traffico); **abort automatico dimostrato** (peso a 0
> senza intervento umano — su un falso positivo NaN, poi fixato: gate ora NaN-proof, agent-log #24).
**D9 chiusa (02/07): Argo Rollouts** al posto del peso manuale (quello = "controller umano su Grafana" =
delivery-infra fatta a mano, stessa categoria del relay outbox pre-Debezium). Dettaglio `docs/design.md §4-D`,
runbook `platform/argo-rollouts/README.md`.
- ✅ **Meccanica**: `orders` = CRD `Rollout` (stesso pod template, `_workload.tpl`); ogni bump CI di `image.tag`
  → ramp automatico 5→25→50→100 sulla `TraefikService` pesata (pesi mossi dal controller, mai in Git).
- ✅ **Canary analysis** (il salto di qualità): AnalysisRun in background sulle query SLO Fase-4 canary-scoped
  (success-rate, ack p99, **failure dei listener Kafka**) → analisi KO = **abort/rollback automatico**.
- ✅ **Blue/green** nativo come strategia alternativa (preview + flip atomico del selector, promozione manuale).
- ✅ **Convivenza GitOps**: `ignoreDifferences` (managedFieldsManagers) + `RespectIgnoreDifferences` sull'app
  Argo CD; controller pinnato (chart 2.41.0/app v1.9.0) con i flag `traefik.io` (senza = lookup falliti).
- ✅ **Regola di release (async)**: canary/preview **condividono il consumer group** → il peso governa solo
  l'intake HTTP; invariante = compatibilità comandi/reply tra versioni adiacenti (v. design §4-D).
- ✅ Validazione precedente del meccanismo manuale su kind (30/06: split 12/12, b/g al colore attivo) +
  **E2E Rollouts su kind** (ramp automatico + abort). La prova live su AKS = parte della demo Fase 6.

## Fase 6 — Chaos + postmortem + demo 🔄 (runbook riscritti async — resta l'ESECUZIONE)
- ✅ **Runbook riscritti per l'async (02/07)** — ora **8 esperimenti** (`docs/chaos/`, manifest in
  `platform/chaos-mesh/`): 01 payments-latency (consumer lento = lag+sweeper, non errori — il rimpiazzo del
  breaker sotto test); 02 pod-kill inventory (never-oversell sotto redelivery); 03 node disruption; 04
  kafka-partition (**il centrale**: outage = ritardo, mai corruzione); 05 failover CNPG (RPO=0 **+ CDC
  riprende** — postura DECISA (03/07): PG16 self-healing via sweeper, perdita notification accettata); **06 kill worker Kafka Connect** (HA del CDC); **07 chaos sul canary → auto-abort Rollouts**
  (lega F5+F6, candidato demo/postmortem); **08 poison message → DLT** (la claim core del Pilastro C,
  provata). Traceability test→esperimenti riscritta sui test attuali.
- ⬜ **Esecuzione live su AKS** (sessione team): run degli 8 in ordine (v. `docs/chaos/README.md`), evidence
  nelle sezioni Observation, criteri PASS spuntati.
- ⬜ **Postmortem** blameless (candidato: il 07 come "bad deploy") + **demo registrata ~5 min** (sistema
  vivo, dashboard, canary auto-abort, un alert).

---

## Decisioni aperte
- **Resilienza async**: quali pattern re-introdurre (bulkhead esplicito? KEDA? breaker attorno a PayPal?) — vedi Fase 2.
- **PayPal**: PSP reale vs mock (la traccia è domain-agnostica → mock accettabile; PayPal = polish + home del breaker).
- ~~**D9**: TraefikService vs Argo Rollouts~~ → **CHIUSA 02/07: Argo Rollouts** (canary analysis automatica sulle SLO; v. Fase 5).
- ~~**Debezium slot-failover**~~ → **CHIUSA 03/07: NO PG17** — restiamo su PG16; il sweeper self-heals il money
  path nel gap, la perdita notification (best-effort) è accettata. Il chaos #5 dimostra questa postura.

## Verificare in locale
```bash
# app repo:   just test-all
# config repo: helm lint ./deploy/charts/eurotransit ; helm template eurotransit ./deploy/charts/eurotransit
```
> Regola d'oro: **nessuno modifica il cluster a mano** — si cambia Git, Argo allinea. Ogni scelta non ovvia va in `docs/` (è lì che si prende il voto).
