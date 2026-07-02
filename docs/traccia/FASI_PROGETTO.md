# EuroTransit — Fasi del progetto (dove siamo, cosa manca)

**Mappa di avanzamento** condivisa: a che punto siamo, cosa è fatto/verificato, cosa resta. Aggiornala quando
una fase cambia stato. Il **design + scelte implementative** (alto livello) sta in `docs/design.md`; gli errori
degli agenti (gradato) in `docs/agent-log.md`.

> **DOVE SIAMO (02/07/2026):** Fasi 0-5 fatte; il money path è stato **riscritto da HTTP sincrono a saga async
> Kafka command/reply** + **Debezium CDC** (outbox letto dal WAL, no relay a polling) — mergiato in `app/dev` e
> `config/main`. Leftover sync rimossi; docs consolidati (design.md unico per repo). **Fase 5 rifatta prod-grade:
> Argo Rollouts** (canary SLO-gated con abort automatico; D9 chiusa). **Resta:** resilienza async da ri-collocare
> (decisione PayPal/KEDA — Fase 2), tracing (Riccardo), monitoring CDC/lag (Dario, Fase 4) e la **Fase 6**
> (chaos, da riscrivere sull'async). Cluster AKS **fermo** (zero costi).

Legenda: ✅ fatto · 🔄 in corso · ⬜ da fare

```text
 Fase 0  Fondamenta             ✅
 Fase 1  Core money path        ✅   ← 6 servizi; saga ora ASYNC Kafka command/reply + outbox
 Fase 2  Resilienza             🔄   ← edge @RateLimiter (429) + DLT/retry async OK; breaker/bulkhead da ri-collocare
 Fase 3  Piattaforma su cluster ✅   ← verificata su AKS; + Debezium (Kafka Connect 3 repliche, CNPG logical)
 Fase 4  Observability          🔄   ← metriche+SLO+dashboard validate LIVE; resta tracing (Riccardo) + CDC/lag monitoring
 Fase 5  Progressive delivery   ✅   ← Argo Rollouts: canary SLO-gated (abort automatico) + blue/green
 Fase 6  Chaos + postmortem     ⬜   ← 5 esperimenti (da riscrivere per l'async) + postmortem + demo
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
- ⬜ **Nota aperta:** lo slot logico Debezium non fa failover nativo su PG → dopo un failover CNPG il CDC va
  ripristinato (mitigazione + verifica nel chaos #5).

## Fase 4 — Observability 🔄 (core validato LIVE; resta tracing + CDC monitoring)
- ✅ **Metriche+SLO+alert**: kube-prometheus adotta le nostre ServiceMonitor (validato LIVE su AKS 29/06); rule
  `eurotransit-checkout-slo` (success-rate intake ≥99% + ack p99, burn-rate multi-finestra; 429 non è errore; mai su CPU).
- ✅ **Dashboard as-code** (RED per servizio + Runtime/golden-signals) caricate in Grafana.
- ✅ **Fix capacità (PR #9, verificato LIVE 30/06):** CPU requests `100m→50m` (fix di booking) → gli standby CNPG
  schedulano, observability + HA CNPG **coesistono** sui 3× B2s_v2.
- 🔄 **Tracing cross-Kafka (implementato 02/07, da validare E2E)**: il producer è **Debezium, non la
  KafkaTemplate** → il contesto W3C si persiste come colonna `traceparent` della riga outbox (stessa tx,
  branch app `fase-4-tracing`) e l'EventRouter lo mappa a header Kafka
  (`table.fields.additional.placement`); consumer con `listener.observation-enabled`. Da validare su kind:
  una traccia unica orders→inventory→payments in Tempo. ⚠️ verifica post-deploy: il tag `result` di
  `spring_kafka_listener_seconds` può cambiare con l'observation → gate `canary-consumer-failures` di
  Fase 5 da ricontrollare (v. agent-log #21).
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
- ⬜ **Ultima miglia correlazione (#8, rimandata)**: datasource Tempo in Grafana + exemplar (metric↔trace);
  Loki opzionale (i log ECS portano già traceId/spanId).

## Fase 5 — Progressive delivery ✅ (Argo Rollouts — canary SLO-gated + blue/green)
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
  riprende** — due posture: PG16 self-healing via sweeper / PG17 failover slots = zero-gap, decisione
  pendente); **06 kill worker Kafka Connect** (HA del CDC); **07 chaos sul canary → auto-abort Rollouts**
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
- **Debezium slot-failover**: mitigazione per il failover CNPG.

## Verificare in locale
```bash
# app repo:   just test-all
# config repo: helm lint ./deploy/charts/eurotransit ; helm template eurotransit ./deploy/charts/eurotransit
```
> Regola d'oro: **nessuno modifica il cluster a mano** — si cambia Git, Argo allinea. Ogni scelta non ovvia va in `docs/` (è lì che si prende il voto).
