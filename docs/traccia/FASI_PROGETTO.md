# EuroTransit — Fasi del progetto (dove siamo, cosa manca)

Questo documento è la **mappa di avanzamento** condivisa: dice a che punto siamo, cosa è già fatto e verificato, e cosa resta — in ordine, così possiamo procedere senza perderci. Aggiornalo quando una fase cambia stato.

> **DOVE SIAMO ORA (28/06/2026): Fase 0/1 ✅. Fase 2 (resilienza) consolidata su `app/main` (test Testcontainers
> da rieseguire localmente). Fase 3 ✅ VERIFICATA sul cluster reale `lab_g03_cluster`: registry CI riallineato a
> `labg03clusterregistry` (era `etg03registry`, vedi agent-log #14), CI verde (tag `3af035e` in ACR + bump su config
> main), Argo CD **Synced & Healthy**, drift selfHeal+prune dimostrati, replica **sincrona** CNPG (inventory/orders
> `sync_state=quorum`, RPO=0), secret `<db>-app` iniettati, TLS Let's Encrypt **prod** su `158.158.71.17.sslip.io`,
> money-path `POST /api/orders` → **CONFIRMED**.
> **Fase 2 §6+§7 CHIUSI (28/06/2026):** §6 validato **live** sul cluster (6.1 probe readiness=db+readinessState senza kafka; 6.2 PDB
> regge un `drain` con money-path mai a 0 + failover CNPG pulito; 6.4 HPA solo catalog/orders; 6.5 graceful shutdown = 45/45 `202`
> + log `cooperative shutdown`; 6.6 notifications=0 → checkout CONFIRMED). §7-codice fatto (structured logging ECS + coerenza
> metriche + guard low-cardinality). **Finding §6.3:** topology spread soft (`ScheduleAnyway`) → payments co-locate su un nodo
> (rivedere `DoNotSchedule`). §7.2 dashboard / §7.4 alert = Fase 4. Cluster **fermato** (`az aks stop`) a fine validazione.**

Legenda stato: ✅ fatto · 🔄 in corso · 🔜 prossima · ⬜ da fare

```text
 Fase 0  Fondamenta            ✅
 Fase 1  Core money path       ✅   ← codice dei 5 servizi, tutti i test verdi
 Fase 2  Resilienza            ✅   ← CB/bulkhead/retry/429/void + test; §6 validato LIVE + §7-codice (28/06/2026)
 Fase 3  Piattaforma su cluster ✅   ← verificata sul cluster reale (2026-06-28): Argo Synced&Healthy, sync CNPG, money-path CONFIRMED
 Fase 4  Observability         🔄   ← core (metriche+SLO+alert+dashboard) ✅ validato LIVE 2026-06-29; resta TRACING (deferito a kind)
 Fase 5  Progressive delivery  🔄   ← canary (Traefik TraefikService) implementato + helm-validato; resta blue/green + prova live
 Fase 6  Chaos + postmortem    ⬜   ← i 5 esperimenti chaos stanno QUI, non in Fase 4
```

Riferimenti utili mentre lavorate:
- `capstone-application-g03/NOTE_IT.md` — come è fatto un servizio (gli strati).
- `capstone-configuration-g03/NOTE_ID.md` — come è fatta la config repo + aggancio alle scelte.
- `capstone-configuration-g03/docs/design.md` — le 12 decisioni di design con razionale.
- `GUIDA-STRUTTURA-REPOSITORY.md` — vista d'insieme dei due repo.

---

## Fase 0 — Fondamenta ✅

Lo scheletro su cui tutto il resto poggia.

- ✅ I due repository (`application` + `configuration`) col modello GitOps dei Lab03/04.
- ✅ Scheletro dei 5 servizi (Kotlin 2.2.21 / Spring Boot 4.0.3 / JDK 21), package `it.g03.<svc>`.
- ✅ CI a matrice (build+test+push per servizio, **niente credenziali del cluster**).
- ✅ `justfile` stile Lab01 (`just verify <svc>` = build→test→container→health→cleanup).
- ✅ `docs/` di team avviati: DoD, design (decisioni 1–12), SLO, threat-model, **agent-log** (6 voci).

## Fase 1 — Core money path ✅

Tutta la logica di dominio dei 5 servizi. **Tutti buildano e i test sono verdi (~32 test).**

- ✅ **Inventory** — risorsa contesa: UPDATE atomico (`never oversell`), idempotenza, state machine prenotazione, reconciler coroutine. 12 test (incl. 2 di concorrenza: "ultimo posto" e duplicati).
- ✅ **Payments** — `authorize` **strettamente idempotente** (`UNIQUE(order_id)` = niente doppio addebito), PSP mock deterministico. 7 test.
- ✅ **Orders** — l'orchestratore: **outbox transazionale** + relay a Flow coroutine, **saga** orchestrata (reserve → authorize → confirm) con compensazioni e ripresa da crash. 11 test.
- ✅ **Catalog** — read API pubblica, seed allineato a Inventory.
- ✅ **Notifications** — consumer fully-async + sink mock (degradazione controllata).
- ✅ Resilience4j verificato su Spring Boot 4 (asserzione sul bean `CircuitBreakerRegistry`).

> Cosa NON c'è ancora in Fase 1: le **policy** di resilienza vere e proprie (vedi Fase 2). I gateway sincroni di Orders hanno già i timeout, ma circuit breaker/retry/bulkhead/429 sono il prossimo passo.

## Fase 2 — Resilienza applicativa 🔜 (SI RIPARTE DA QUI)

Rendere il sistema capace di **contenere** il guasto, non propagarlo (Pilastro C).

- ⬜ **Circuit breaker** Resilience4j su Orders → Payments (policy open/half-open + fallback).
- ⬜ Stato **`PAYMENT_PENDING`** come fallback quando il breaker è aperto (oggi l'ordine resta PENDING/RESERVED).
- ⬜ **Retry** con backoff + jitter e **bulkhead** sulle chiamate cross-service.
- ⬜ **Backpressure / load shedding**: HTTP **429** sotto sovraccarico invece di accodare fino al collasso.
- ⬜ **Test funzionale** del circuit breaker (provare apertura → fallback → half-open), non solo che il bean esista.
- ⬜ Compensazione **refund/void** su Payments per il caso `RESERVATION_EXPIRED` (oggi è un TODO in `OrderSaga`).
- ℹ️ Probe / PDB / HPA / topology spread a livello K8s sono **già scritti** nel chart (Fase 0/1); qui si valida che funzionino col codice.

## Fase 3 — Piattaforma sul cluster reale ✅ (verificata 2026-06-28)

Il sistema gira davvero su `lab_g03_cluster` (AKS, 3× B2s_v2), riconciliato da Argo CD.

- ✅ Componenti di piattaforma: Traefik, cert-manager, **CloudNativePG 1.29.1**, **Strimzi 1.0.0** (Kafka 4.1.2 Ready, 7 topic), Sealed Secrets, Argo CD — tutti Running.
- ✅ CI collegata ai repo veri (secret `ACR_USERNAME/PASSWORD` + `CONFIG_REPO_PAT` + var `GITOPS_REPO`): pipeline verde, immagini `3af035e` in `labg03clusterregistry`, bump tag su config main. ⚠️ Fix registry: CI puntava a `etg03registry` inesistente → riallineato (agent-log #14).
- ✅ Argo CD **Synced & Healthy**; drift dimostrato: selfHeal (scale `inventory`→5 ritorna a 2) + prune (`delete notifications` ricreato).
- ✅ Replica **sincrona** CNPG: `inventory-db` (3 ist., `dataDurability=required`) e `orders-db` (2 ist., `preferred`) con standby `streaming sync_state=quorum`, `ANY 1 (...)` → RPO=0. Secret `<db>-app` iniettati (pod `orders`: `DB_HOST=orders-db-rw`, ecc.).
- ✅ Extra provati: TLS Let's Encrypt **prod** (`158.158.71.17.sslip.io`, HTTP 200 senza `-k`), money-path `POST /api/orders` → `PENDING→RESERVED→CONFIRMED`.

## Fase 4 — Observability 🔄 (core ✅ validato LIVE 2026-06-29; manca il tracing)

Dashboard e SLO che **guidano decisioni** (Pilastro D, continua dal Lab05).

**Validato sul cluster reale `lab_g03_cluster` (2026-06-29, via GitOps — PR #4 mergiata, Argo riconcilia):**
- ✅ **kube-prometheus-stack** adotta le nostre CR: **6 ServiceMonitor → 17 target** scrapati (catalog/inventory/payments/notifications/orders UP; `users` DOWN = immagine `:latest` mai buildata; 1 pod `orders` DOWN = config-error — roba backend, non observability).
- ✅ **SLO**: `PrometheusRule eurotransit-checkout-slo` caricata e **`health=ok`** — 4 recording (error-ratio 5m/30m/1h/6h) + 3 **alert symptom-based** (burn-rate fast/slow + ack-latency), mai sulla CPU. SLI come da `docs/slo.md`.
- ✅ **Dashboard as-code** caricate dalla sidecar Grafana: **RED** per servizio + **Runtime/golden-signals** (JVM heap/CPU/thread/GC, dati live). I pannelli "checkout intake" sono vuoti finché `orders` non serve traffico `/api/orders` (atteso). **USE infra** = dashboard native di kube-prometheus.
- 🔄 **Tracing distribuito (OTel Collector + Tempo)**: pipeline **montata e provata su kind** (Collector + Tempo + Grafana healthy). **MA le app non esportano span** pur avendo dipendenze+config corrette (le metriche Prometheus vanno) → **TODO Riccardo: fix del wiring trace-export su Spring Boot 4, su `dev`** (l'ha già fatto in webapp2, deve adattarlo al cluster). La traccia live si cattura lì. (La saturazione CPU che bloccava l'HA è stata **risolta** — vedi finding sotto, PR #9 — quindi il blocco del tracing è ora solo lato app, non di capacità.)
- ⬜ (rifinitura) dashboard **Kafka consumer-lag** + **CNPG** pronte ma gated finché non si abilitano gli exporter (kafka-exporter / CNPG PodMonitor).

> **FINDING capacità — risponde al dubbio "3 nodi non bastano più? strano" (Dario, 2026-06-29).**
> Non è il *numero* di pod né l'uso reale di CPU (~50% sui nodi). È la **somma delle CPU _requests_** (prenotazioni):
> lo scheduler piazza i pod per *richiesta riservata*, non per uso effettivo. I 3× B2s_v2 = 6 vCPU (allocatable
> ~5.4 dopo le riserve di sistema) bastavano per lo stack app (Fase 3 girava). **La Fase 4 ha aggiunto
> kube-prometheus-stack** (Prometheus + Alertmanager + Grafana + kube-state + node-exporter ×3), che prenota una
> fetta importante → la somma delle requests supera l'allocatable e i pod "extra" restano **Pending: Insufficient
> cpu** (visto su `orders-db-2` e `inventory-db-2`, le 3ª/2ª repliche CNPG, su tutti e 3 i nodi). È il costo,
> previsto, di mettere l'osservabilità su un cluster già pieno. **Opzioni (decisione team):** (a) abbassare
> requests/repliche non critiche (es. `inventory-db` 3→2, requests più basse), oppure (b) alzare il node pool
> (più costo — evitato per ora, credito ~63€). Conseguenza pratica: su questo cluster ci stanno **o** gli standby
> HA al completo **o** lo stack observability — *quando le request erano a 100m*.
>
> ✅ **RISOLTO + VERIFICATO LIVE (30/06/2026, PR #9 di Dario).** Scelta (a): CPU *requests* abbassate **`100m → 50m`**
> su `resources` (servizi) e `databaseResources` (istanze CNPG). È un fix di **booking**, non di capacità (uso reale
> ~50%, nessun CPU limit → niente throttling), mirato ai DB (no HPA → nessun effetto autoscaling). Su AKS: Argo ha
> riconciliato i 50m e **tutti gli 8 instance CNPG vanno Running**, inclusi i prima-bloccati `orders-db-2`,
> `inventory-db-2`, `inventory-db-3` → **niente più `Pending: Insufficient cpu`**. Observability completa + HA CNPG ora
> **coesistono** sui 3× B2s_v2. (Restano non-Running solo `orders` = secret `orders-oidc` e `users` = immagine: problemi
> backend, non-CPU.) Cluster rifermato subito dopo il test (~15 min uptime).

## Fase 5 — Progressive delivery 🔄 (canary implementato + helm-validato)

Due strategie, entrambe dimostrate (Pilastro D).

- 🔄 **Canary** via Traefik `TraefikService` (pesi 95/5 → 50/50 → 0/100 osservando le SLI) — **implementato nel chart**
  (helm lint/template ok): refactor del workload in `templates/_workload.tpl` (stable+canary da UNA definizione, niente
  drift), `templates/canary.yaml` (workload `orders-canary`, gated da `services.orders.canary.enabled`, default OFF),
  `templates/ingressroute-orders.yaml` (IngressRoute `/api/orders` → `TraefikService` pesata stable/canary), Ingress
  standard che molla `/api/orders` quando il canary è attivo, e `providers.kubernetesCRD` abilitato in Traefik.
  Promozione **GitOps-native**: si edita `canary.weight` e si committa, guardando le SLO; rollback = weight 0. **Resta**
  la prova live sul cluster (deploy di un tag canary + osservare lo split).
- ⬜ **Blue/green** (due colour-track + switch 100/0 del routing, rollback istantaneo) — stesso meccanismo, follow-up.
- ⬜ Discutere perché all-at-once e rolling **non** si usano sul percorso critico (no controllo dell'esposizione /
  no osservazione prima di promuovere) → vedi `RECAP_FASI`/design.
- ℹ️ Decisione **D9**: scelto `TraefikService` (peso in Git, promozione umana sulle SLI), non Argo Rollouts
  (che automatizzerebbe la promozione) — citare Rollouts come alternativa all'orale.

## Fase 6 — Chaos + postmortem + demo ⬜

Provare che la resilienza è una proprietà, non un'ipotesi.

- ⬜ I **5 esperimenti** Chaos Mesh (latenza Payments, pod-kill Inventory, node disruption, partizione Kafka, failover primary CNPG), ognuno con report in `docs/chaos/`.
- ⬜ **Postmortem** blameless dell'incidente live (template già pronto).
- ⬜ **Demo registrata ~5 min** (link nel repo): sistema vivo, dashboard, un canary, un blue/green, un alert che scatta.

---

## Decisioni ancora aperte (da chiudere col team)

- **D2** — un controllo auth minimale al gateway? (oggi: nessuno).
- **D9** — solo `TraefikService` per il canary, o valutare anche Argo Rollouts?
- **D12 (variante)** — `inventory-db` a 3 istanze (scelto) vs 2 (1 pod in meno, ma blocca le scritture se la standby è giù).

## Come verificare in locale (per chi prende in mano il codice)

```bash
# nell'application repo:
just test-all            # tutti i test dei 5 servizi
just run catalog         # avvia un servizio su :8080 (H2, zero dipendenze)
just verify orders       # build → container → health-check → cleanup di un servizio

# nel configuration repo:
helm lint ./deploy/charts/eurotransit
helm template eurotransit ./deploy/charts/eurotransit   # vede i manifest finali
```

> Regola d'oro del progetto: **nessuno modifica il cluster a mano.** Si cambia Git, Argo CD allinea. E ogni scelta non ovvia va annotata in `docs/` (è lì che si prende il voto).
