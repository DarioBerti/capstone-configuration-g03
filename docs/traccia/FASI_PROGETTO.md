# EuroTransit — Fasi del progetto (dove siamo, cosa manca)

Questo documento è la **mappa di avanzamento** condivisa: dice a che punto siamo, cosa è già fatto e verificato, e cosa resta — in ordine, così possiamo procedere senza perderci. Aggiornalo quando una fase cambia stato.

> **DOVE SIAMO ORA (21/06/2026): Fase 0 e Fase 1 COMPLETE e verificate. Prossima: Fase 2 (resilienza applicativa).**

Legenda stato: ✅ fatto · 🔜 prossima · ⬜ da fare

```text
 Fase 0  Fondamenta            ✅
 Fase 1  Core money path       ✅   ← codice dei 5 servizi, tutti i test verdi
 Fase 2  Resilienza            🔜   ← SI RIPARTE DA QUI
 Fase 3  Piattaforma su cluster ⬜
 Fase 4  Observability         ⬜
 Fase 5  Progressive delivery  ⬜
 Fase 6  Chaos + postmortem    ⬜
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

## Fase 3 — Piattaforma sul cluster reale ⬜

Far girare davvero il sistema (finora tutto è locale + chart validata con `helm template`).

- ⬜ Installare i componenti di piattaforma (Traefik, cert-manager, **CloudNativePG ≥ 1.25**, **Strimzi**, Sealed Secrets, Argo CD).
- ⬜ Collegare la CI ai repo GitHub veri (secret ACR + PAT del config repo).
- ⬜ Far raggiungere ad Argo CD lo stato **Synced & Healthy**; provare drift + reconcile.
- ⬜ Verificare la **replica sincrona** CNPG e i secret `<db>-app` iniettati nei pod.

## Fase 4 — Observability ⬜

Dashboard e SLO che **guidano decisioni** (Pilastro D, continua dal Lab05 — ancora da fare).

- ⬜ kube-prometheus-stack + **Tempo/OTel Collector** (decisioni già pinnate in `platform/observability`).
- ⬜ Dashboard **RED** per servizio, **USE** infra, **Kafka consumer lag**, CNPG.
- ⬜ **SLO** del checkout (success-rate + latenza) con SLI misurate dove deciso in `docs/slo.md`.
- ⬜ **Alert solo symptom-based** (burn-rate multi-finestra), mai sulla CPU.
- ⬜ Tracing distribuito che attraversa Kafka (contesto propagato negli header).

## Fase 5 — Progressive delivery ⬜

Due strategie, entrambe dimostrate (Pilastro D).

- ⬜ **Canary** via Traefik `TraefikService` (pesi 95/5 → 50/50 → 0/100 osservando le SLI).
- ⬜ **Blue/green** (due deployment, switch del routing, rollback rapido).
- ⬜ Discutere perché all-at-once e rolling **non** si usano sul percorso critico.

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
