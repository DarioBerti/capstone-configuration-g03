# EuroTransit — Fasi del progetto (dove siamo, cosa manca)

**Mappa di avanzamento** condivisa: a che punto siamo, cosa è fatto/verificato, cosa resta. Aggiornala quando
una fase cambia stato. Il **design + scelte implementative** (alto livello) sta in `docs/design.md`; gli errori
degli agenti (gradato) in `docs/agent-log.md`.

> **DOVE SIAMO (01/07/2026):** Fasi 0-5 fatte; il money path è stato **riscritto da HTTP sincrono a saga async
> Kafka command/reply** + **Debezium CDC** (outbox letto dal WAL, no relay a polling) — mergiato in `app/dev` e
> `config/main`. Rimossi i leftover del flusso sync (client `orders-svc` / secret `orders-oidc` / URL sync).
> **Resta:** riallineo docs (in corso), reintrodurre i pattern di resilienza in versione async (decisione team),
> e la **Fase 6** (chaos, da riscrivere sull'async). Cluster AKS + kind **fermi** (zero costi).

Legenda: ✅ fatto · 🔄 in corso · ⬜ da fare

```text
 Fase 0  Fondamenta             ✅
 Fase 1  Core money path        ✅   ← 6 servizi; saga ora ASYNC Kafka command/reply + outbox
 Fase 2  Resilienza             🔄   ← edge @RateLimiter (429) + DLT/retry async OK; breaker/bulkhead da ri-collocare
 Fase 3  Piattaforma su cluster ✅   ← verificata su AKS; + Debezium (Kafka Connect 3 repliche, CNPG logical)
 Fase 4  Observability          🔄   ← metriche+SLO+dashboard validate LIVE; resta tracing (Riccardo) + CDC/lag monitoring
 Fase 5  Progressive delivery   ✅   ← canary + blue/green validati LIVE su kind
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
- 🔄 **Tracing distribuito (OTel Collector + Tempo)**: pipeline provata; **le app devono esportare gli span** →
  **TODO Riccardo** (wiring trace-export su Boot 4 + traceId sugli header Kafka per vedere l'intera pipeline).
- ⬜ **Da abilitare ora che la saga è Kafka:** dashboard **consumer-lag** + monitoraggio **CDC/Connect** (stato
  connector, slot) con allarme "connector down / slot che cresce".

## Fase 5 — Progressive delivery ✅ (canary + blue/green — validati LIVE su kind)
Meccanismo GitOps-native via CRD Traefik (dettaglio in `docs/design.md §4-D`).
- ✅ **Canary**: `IngressRoute /api/orders` → `TraefikService` pesata (`orders`/`orders-canary`); peso in `values.yaml`,
  promozione 5→50→100 = commit sulle SLO, rollback = weight 0. Refactor `_workload.tpl` (stable+canary una definizione).
- ✅ **Blue/green**: `orders-green` a piena capacità + IngressRoute 100% al colore `active` (switch atomico); mutuamente
  esclusivo col canary (`fail` se entrambi).
- ✅ **Validati LIVE su kind (30/06):** canary weight=50 → split 12/12; blue/green → ~100% al colore attivo.
- ⬜ (valutare) **Argo Rollouts** per l'analisi automatica (D9); la prova live su AKS = parte della demo Fase 6.

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
- **D9**: `TraefikService` (scelto) vs Argo Rollouts (analisi automatica).
- **Debezium slot-failover**: mitigazione per il failover CNPG.

## Verificare in locale
```bash
# app repo:   just test-all
# config repo: helm lint ./deploy/charts/eurotransit ; helm template eurotransit ./deploy/charts/eurotransit
```
> Regola d'oro: **nessuno modifica il cluster a mano** — si cambia Git, Argo allinea. Ogni scelta non ovvia va in `docs/` (è lì che si prende il voto).
