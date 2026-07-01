# Fase 6 — Chaos engineering + postmortem + demo: piano tecnico dettagliato

> Documento di lavoro del team, **per il team e per l'orale**. Porta il sistema dall'avere *policy di resilienza
> implementate e validate live* (Fasi 2–5) al **provare** che la resilienza è una proprietà, non un'ipotesi:
> *"Resilience that has never been tested is a hypothesis, not a property. You will validate yours."* (spec p.4).
> Generato il 2026-06-30 (Fase 5 appena chiusa su `configuration/main`).
> Complementare a `traccia/FASI_PROGETTO.md` (Fase 6), `design.md`, `slo.md`, `platform/chaos-mesh/README.md`, `docs/chaos/`.
> Ancorato ai file **già esistenti** (§0) e al **deck 11** (Resilience) / **deck 10** (Observability) / **spec p.4–7**.

> **DECISIONI DI SCOPE (team, 2026-06-30):** run **ibrido kind + AKS** (D6-A); **un solo** documento (questo);
> i blocker AKS del money-path sono **prerequisiti gating** (§Prerequisiti) — questo piano **non** scrive codice backend.

---

## ⭐ La Fase 6 in sintesi — 10 PUNTI

La traccia chiede **3 deliverable** (spec p.4–6): **5 esperimenti chaos** + **1 postmortem blameless** + **1 demo ~5 min**.
Operativamente si scompongono in **10 punti numerati (P1…P10)**. Lo scaffold (manifest, report, k6, template) è **già scritto**
(§0): la Fase 6 è soprattutto **esecuzione + evidenze**.

| # | Punto | Tipo | Stato | Dove | **Parallelizzabile?** |
|---|---|---|---|---|---|
| **P1** | Pin + install Chaos Mesh | infra-prereq | ⬜ | kind + AKS | **Sì** — install indipendente per-cluster (sblocca P2–P6) |
| **P2** | Esperimento 01 — Payments latency | esperimento | 🔄 scaffold ✅ · run ⬜ | **kind** | **Sì** — kind dedicato (con P3, P4, P7) |
| **P3** | Esperimento 02 — Inventory pod-kill | esperimento | 🔄 scaffold ✅ · run ⬜ | **kind** | **Sì** — kind dedicato (con P2, P4, P7) |
| **P4** | Esperimento 04 — Kafka partition | esperimento | 🔄 scaffold ✅ · run ⬜ | **kind** | **Sì** — kind dedicato (con P2, P3, P7) |
| **P5** | Esperimento 03 — Node disruption (drain) | esperimento | 🔄 metà-provato ✅ · run ⬜ | **AKS** | **No tra loro:** P5 e P6 **sequenziali su AKS**; **Sì** vs i kind |
| **P6** | Esperimento 05 — CNPG primary failover | esperimento | 🔄 scaffold ✅ · run ⬜ | **AKS** | **No tra loro:** P5 e P6 **sequenziali su AKS**; **Sì** vs i kind |
| **P7** | Graceful degradation (Notifications giù) | test esplicito | ⬜ (parz. §6.6) | **kind** | **Sì** — kind dedicato (con P2–P4) |
| **P8** | Postmortem blameless | deliverable | ⬜ | — | **No** — a valle: dipende dall'esperimento-incidente |
| **P9** | Demo ~5 min registrata | deliverable | ⬜ | AKS | **No** — a valle: dipende da P2/P6 (alert) + canary/blue-green |
| **P10** | Riallineo docs / DoD / agent-log / design | chiusura | ⬜ | — | **Parziale** — ogni report si riempie col suo esperimento; riallineo finale a valle |

**Lettura rapida della parallelizzazione (dettaglio in §Parallelizzazione):**
- **5 punti partono SUBITO in parallelo** su cluster separati: **P2, P3, P4, P7** (kind) **+ uno tra P5/P6** (AKS).
- **Vincolo cardine:** *un esperimento alla volta **PER cluster*** → su AKS **P5 poi P6** (mai insieme); il parallelismo reale viene da **più cluster**.
- **3 punti sono a valle** (non parallelizzabili in avvio): **P8** (postmortem), **P9** (demo), **P10** (riallineo finale) — dipendono dagli esperimenti.
- **P1** è prerequisito di P2–P6 ma l'install è indipendente per-cluster (kind e AKS in parallelo).

---

## §0. Stato di partenza — cosa è GIÀ FATTO (non si riparte da zero)

Lo scaffold è stato portato avanti in Fase 4 (`agent-log.md #17`). **La maggior parte dell'artefatto esiste**; manca l'esecuzione live + le evidenze.

| Artefatto | Path | Stato |
|---|---|---|
| 5 manifest Chaos Mesh (commentati, con ipotesi inline) | `platform/chaos-mesh/01..05-*.yaml` | ✅ **scritti e completi** ("i 5 test della Fase 6") |
| Runbook chaos (safety model · install · loop · label) | `platform/chaos-mesh/README.md` | ✅ completo (versione `<PINNED>` da scegliere — P1/D6-B) |
| 5 report esperimento | `docs/chaos/01..05-*.md` | 🔄 **Steady-state/Ipotesi/Blast/Method scritti**; `## Observation` + `## Conclusion` = **placeholder** |
| Template report + lista pianificata | `docs/chaos/README.md` | ✅ completo |
| Traceability test-unit ⇄ chaos (`@Tag("chaos-NN")`) | `docs/chaos/test-traceability.md` | ✅ completo · tag in app: 01=9, 02=7, 03=2, 04=1, 05=0 |
| Evidenze K8s live (probe/PDB/topology/graceful/degrad.) | `docs/chaos/fase2-6-k8s-validation.md` | ✅ evidenze **reali** — chaos #3 **già metà-provato** (§6.2/6.3), degradazione (§6.6) |
| Template postmortem blameless | `docs/postmortem.md` | ✅ template (da riempire post-incidente) |
| Load generator money-path | `platform/k6/money-path.js` + `README.md` | ✅ scritto (200/201/202=ok, **429=shed a parte**, solo 5xx contro budget) |
| Recipe `chaos-install` + `loadtest` | `justfile` (`chaos-install` r.362, `loadtest` r.374) | ✅ presenti (versione Chaos Mesh non pinnata) |

---

## §0bis. Principi guida (il metodo che la traccia pretende)

Il chaos **non è "rompere a caso"**: è il **metodo scientifico applicato alla resilienza** (deck 11 s.41 + spec p.4–5, parole identiche):

> *define steady state (your SLIs) → state a hypothesis → inject **one** failure → observe (in your **own** dashboards) → conclude → fix.*

Quattro regole non negoziabili (già nel "Safety model" di `chaos-mesh/README.md`):
- **Observability è prerequisito** (deck 11 s.40/45: *"instrument first; chaos test second"*) → la Fase 4 (core ✅, 2026-06-29) **deve essere su**.
- **Una variabile alla volta** → mai due esperimenti insieme **sullo stesso cluster** (è la base della parallelizzazione: §Parallelizzazione).
- **Blast radius limitato + abort condition** (deck 11 s.41: *"never inject a failure without a rollback or abort condition"*) → time-based (01,04) auto-revertono via `duration`; pod-kill (02,05) one-shot self-heal; tutti hanno `kubectl delete -f`.
- **Begin in staging, not production** (deck 11 s.41) → motiva l'**ibrido** (D6-A): prova/parallelo su **kind**, headline+demo su **AKS**.

---

## §Decisioni (D6-A … D6-G)

| # | Decisione | Scartata | Perché | Punti |
|---|---|---|---|---|
| **D6-A** | ✅ **Run ibrido kind + AKS** | Solo AKS · solo kind | "1 esperimento/cluster" → parallelismo solo con **più cluster**: kind usa-e-getta paralleli (+ "staging-first") per P2/P3/P4/P7; AKS per la **postura reale** (P5 drain nodi gestiti/PDB, P6 CNPG 3-istanze sync) e la demo. | P2–P6, §Parallelizzazione |
| **D6-B** | ✅ **Pin versione Chaos Mesh** | `latest` | Policy "operatori pinnati" di `platform/README.md` (Strimzi 1.0.0, CNPG 1.29.1). Sostituire `<PINNED>` in `chaos-mesh/README.md` **e** in `justfile`→`chaos-install`, release **compatibile k8s 1.33**. | P1 |
| **D6-C** | ✅ **Esp. 03 = `kubectl drain`, non un CR** | PhysicalMachineChaos · kill involontario | Chaos Mesh vanilla non evince un nodo AKS gestito; il PDB governa la disruption **volontaria** = drain; su 6 vCPU pieni un kill involontario lascia pod `Pending` (D-C). **Già metà-provato** (§6.2/6.3). | P5 |
| **D6-D** | ✅ **Demo registrata ~5 min, scaletta fissa** | Demo non registrata | spec p.6: link committato + *"at least one alert firing under an injected failure"*. | P9 |
| **D6-E** | ✅ **Abort condition per esperimento** | Nessun abort | deck 11 s.41. Stop = `delete -f` + auto-revert; stop anticipato se success-rate <90% per >1 min o pod `CrashLoopBackOff`. | P2–P6 |
| **D6-F** | ✅ **Chiude D9** — solo `TraefikService` | Argo Rollouts | Peso in Git + promozione umana sulle SLI (Fase 5). Rollouts **citato all'orale** come alternativa, non adottato. | P10 |
| **D6-G** | ⏳ **Chiude finding §6.3 (topology)** — team | — | `ScheduleAnyway` (soft) non garantisce nodi distinti (deck 11 s.12). Opzioni: (a) soft su 3 nodi; (b) `DoNotSchedule` solo `payments`. P5 lo mette alla prova. | P5, P10 |

---

## §I 10 PUNTI — dettaglio operativo

Per ogni punto: **stato · cosa fare · (esperimenti) serie da catturare · risultato atteso · dove · Parallelizzabile · Dipende da**.
La metà superiore di ogni report `docs/chaos/0X-*.md` è **già scritta**: qui si dice cosa **eseguire** e quali serie incollare in `## Observation`/`## Conclusion`.
Label selettori (`chaos-mesh/README.md`): servizi `app.kubernetes.io/name:<svc>` (`_helpers.tpl`), Kafka `strimzi.io/cluster:eurotransit`, primary `cnpg.io/cluster:inventory-db`+`role:primary`.

### P1 — Pin + install Chaos Mesh
- **Stato:** ⬜. **Cosa fare:** scegliere release **compatibile k8s 1.33**, sostituire `<PINNED>` in `chaos-mesh/README.md` + `justfile`→`chaos-install`, poi `just chaos-install` (ns `chaos-mesh`, `--set chaosDaemon.runtime=containerd ... socketPath=/run/containerd/containerd.sock` per AKS).
- **Dove:** kind + AKS. **Parallelizzabile:** ✅ **Sì** — install indipendente su ogni cluster. **Dipende da:** — (è prerequisito di P2–P6).

### P2 — Esperimento 01 · Payments latency · `NetworkChaos` (delay)
- **Manifest:** `platform/chaos-mesh/01-payments-latency.yaml` — `delay`, `mode:all`, `direction:to`, `3s`/`200ms`, `duration:5m`.
- **Steady-state:** success-rate ≥ **99%**, ack **p99 ≤ 300 ms**, Catalog RED nominale, breaker `payments` **CLOSED**.
- **Ipotesi:** ~3 s > soglia slow-call (>2 s) → breaker **OPEN** → `authorize` fast-fail → ordine in **`PAYMENT_PENDING`**; Catalog sano (bulkhead `payments(8)` vs `inventory(16)`); ack SLO **non** sfondato (chiamata fuori dal thread, saga async).
- **Catturare:** `resilience4j_circuitbreaker_state{name="payments"}`→OPEN · `orders_payment_failures_total{outcome="unavailable"}`↑ · `orders_recovery_total` · intake ancora **202** · RED Catalog invariato.
- **Atteso:** dopo revert → HALF_OPEN→CLOSED, recovery sweep drena PAYMENT_PENDING→CONFIRMED.
- **Dove:** **kind**. **Parallelizzabile:** ✅ **Sì** (kind dedicato; con P3, P4, P7). **Dipende da:** P1. **L1:** `chaos-01` (9 test).

### P3 — Esperimento 02 · Inventory pod-kill · `PodChaos`
- **Manifest:** `02-inventory-podkill.yaml` — `pod-kill`, `mode:one` (one-shot).
- **Steady-state/invariante:** `available` **mai < 0**, RESERVED+CONFIRMED **≤ posti**, **una sola** authorization/ordine.
- **Ipotesi:** kill a metà prenotazione → redelivery at-least-once + driver concorrenti; UPDATE atomico `... WHERE available>=qty` + `UNIQUE(order_id,product_id)` + `@Version` = replay idempotente → never oversell, no doppio addebito.
- **Method:** lanciare **durante un burst concorrente sullo STESSO SKU 1-posto**, poi `apply`.
- **Catturare:** query DB invariante (`available>=0`, riservati≤posti) · `inventory_reservations_total{outcome}` · una riga `payment_authorizations`/ordine.
- **Atteso:** convergenza a un esito/ordine → **chiude ☐ Pillar B**.
- **Dove:** **kind**. **Parallelizzabile:** ✅ **Sì** (kind dedicato; con P2, P4, P7). **Dipende da:** P1. **L1:** `chaos-02` (7 test).

### P4 — Esperimento 04 · Kafka partition · `NetworkChaos` (partition)
- **Manifest:** `04-kafka-partition.yaml` — `partition`, A=`orders`, B=ns `kafka` `strimzi.io/cluster:eurotransit`, `both`, `duration:3m`.
- **Steady-state:** intake **202**, consumer-lag ~0, backlog outbox (`published_at IS NULL`) ~0.
- **Ipotesi:** outbox transazionale + consumer idempotenti = niente perso/duplicato. Durante: `POST` resta 202 (ordine+outbox committano localmente); al heal il relay ripubblica (at-least-once), la dedup `UNIQUE` assorbe le redelivery → convergenza.
- **Catturare — durante:** backlog `published_at IS NULL` cresce, intake ancora 202; **dopo heal:** backlog drena, lag→0, ogni ordine **esattamente UNO** stato terminale.
- **Dove:** **kind**. **Parallelizzabile:** ✅ **Sì** (kind dedicato; con P2, P3, P7). **Dipende da:** P1. **L1:** `chaos-04` (1 test).

### P5 — Esperimento 03 · Node disruption · `kubectl drain` (non un CR)
- **Manifest:** `03-node-disruption.yaml` — runbook `cordon`→`drain --ignore-daemonsets --delete-emptydir-data --timeout=120s`→`uncordon`. (D6-C).
- **Steady-state:** **≥1 replica Ready**/servizio critico, orders RED entro SLO.
- **Ipotesi:** PDB `minAvailable:1` + topology spread tengono il critical path; sotto capacità ridotta l'intake **shedda 429 + Retry-After** invece di collassare.
- **Catturare:** evizioni **rispettano i PDB** (deploy ≥ minAvailable; rifiuti `Cannot evict … disruption budget`) · money-path **mai a 0** · **annotare ogni pod `Pending`** (finding 6 vCPU). Mette alla prova **D6-G**.
- **Atteso:** PDB+topology mantengono il critical path. **Già metà-provato** (§6.2) — qui si completano le SLI money-path sotto k6.
- **Dove:** **AKS**. **Parallelizzabile:** ⚠️ **No con P6** (entrambi AKS → **sequenziali**); ✅ **Sì** vs i kind (P2–P4, P7). **Dipende da:** P1. **L1:** `chaos-03` (2 test).

### P6 — Esperimento 05 · CNPG primary failover · `PodChaos`
- **Manifest:** `05-pg-failover.yaml` — `pod-kill`, `mode:one`, `cnpg.io/cluster:inventory-db`+`role:primary`. **Verificare la label prima.**
- **Steady-state:** success-rate intake, posti consistenti, **RPO=0** (inventory-db 3 ist., `dataDurability:required`).
- **Ipotesi:** replica sincrona (dec. 12) → perdita primary = breve stallo scritture in promozione ma **nessuna prenotazione committata persa** → never oversell tiene; intake SLI recupera entro **RTO ≤ 60 s**.
- **Catturare:** `kubectl cnpg status inventory-db` (promozione) · **dip + tempo-recupero** intake SLI (≤60s) · post-failover `available`==stato committato pre (nessuna prenotazione persa).
- **Dove:** **AKS**. **Parallelizzabile:** ⚠️ **No con P5** (entrambi AKS → **sequenziali**); ✅ **Sì** vs i kind. **Dipende da:** P1. **L1:** nessuno diretto (infra pura); analoghi `OrderSagaTest`+`OrderRecoverySweeperTest`.

### P7 — Graceful degradation esplicita (Notifications giù) — chiude ☐ Pillar C
- **Cosa fare:**
  ```bash
  kubectl scale deploy notifications --replicas=0 -n eurotransit   # Notifications giù
  # sotto carico k6:  POST /api/orders  ->  PENDING -> RESERVED -> CONFIRMED
  kubectl scale deploy notifications --replicas=1 -n eurotransit
  ```
- **Atteso:** checkout **CONFIRMED** anche con Notifications a 0 (evento `notification-requested` best-effort, fuori dal money path).
- **Dove:** **kind**. **Parallelizzabile:** ✅ **Sì** (kind dedicato; con P2–P4). **Dipende da:** P1 (no — non serve Chaos Mesh, solo `kubectl scale`).

### P8 — Postmortem blameless (l'incidente live)
- **Cosa fare:** scegliere **un** esperimento come incidente (candidati **P2** latency o **P6** failover — devono far **scattare un alert**), riempire `docs/postmortem.md`: Date/Summary/Impact (budget? never-oversell tenuto?) · Timeline UTC (failure→**primo alert** burn-rate fast14.4×/slow6×→mitigazione→recovery) · Detection (quale SLI/alert/dashboard, quanto veloce) · Recovery (**RTO osservato vs ≤60s**) · went well/didn't · Action items. Citare anti-pattern deck 11 s.45 + *"agent as actor / blast radius"* (spec p.5, `agent-threat-model.md`).
- **Parallelizzabile:** ❌ **No** — a valle. **Dipende da:** l'esperimento-incidente (P2 o P6). *Lo scheletro* si scrive prima in parallelo.

### P9 — Demo ~5 min registrata (link committato)
- **Storyboard (spec p.6):** (1) sistema vivo (`kubectl get pods`, money-path 202→CONFIRMED) · (2) dashboard RED/SLO che **rispondono a una domanda operativa** · (3) **canary** (TraefikService weight, Fase 5) · (4) **blue/green** (switch atomico + rollback) · (5) **un alert che scatta** sotto guasto (P2) + recovery.
- **Cosa fare:** registrare, committare il **link** nel repo (README/`FASI_PROGETTO.md`).
- **Parallelizzabile:** ❌ **No** — a valle. **Dipende da:** P2/P6 (alert) + canary/blue-green (Fase 5). *Lo storyboard* si scrive prima in parallelo.

### P10 — Riallineo docs / DoD / agent-log / design
- `docs/chaos/0X-*.md`: riempire `Observation`+`Conclusion` (linkare `test-traceability.md`; un chaos rosso con unit verde = gap **ambientale**).
- `docs/postmortem.md`: riempito (P8). `FASI_PROGETTO.md`: Fase 6 `⬜→✅` + chiudere D9 (D6-F) e §6.3 (D6-G).
- `capstone-dod.md`: ☑ chaos #2 (B), graceful-degradation (C), 5 esperimenti, postmortem, demo + **riallineare caselle stantie** Fase 4/5.
- `agent-log.md`: voci **#18+** (*Produced → Why wrong → How caught → Fix*). `design.md`: chiudere D9 + annotare §6.3.
- **Parallelizzabile:** ⚠️ **Parziale** — ogni `0X` si riempie **appena finisce il suo esperimento** (per-report in parallelo); il riallineo finale FASI/DoD è **a valle** di tutto.

---

## §Parallelizzazione (la risposta esplicita: quali punti e come)

> **Vincolo cardine:** *un esperimento alla volta **PER cluster*** (safety model) → su un solo cluster gli esperimenti sono
> **sequenziali**. Il parallelismo reale viene da **più cluster** → ecco perché D6-A sceglie **ibrido kind + AKS**.

### Matrice parallelizzazione per punto
| Punto | Parallelizzabile? | Come / con cosa | Dipende da |
|---|---|---|---|
| **P1** install | ✅ Sì | install indipendente per-cluster (kind **e** AKS insieme) | — |
| **P2** exp01 | ✅ Sì | **kind #1** dedicato | P1 |
| **P3** exp02 | ✅ Sì | **kind #2** dedicato | P1 |
| **P4** exp04 | ✅ Sì | **kind #3** dedicato | P1 |
| **P7** graceful-degr. | ✅ Sì | **kind** (solo `kubectl scale`, no Chaos Mesh) | — |
| **P5** exp03 (drain) | ⚠️ vincolato | **AKS**, sequenziale con P6; ✅ parallelo ai kind | P1 |
| **P6** exp05 (CNPG) | ⚠️ vincolato | **AKS**, sequenziale con P5; ✅ parallelo ai kind | P1 |
| **P8** postmortem | ❌ No (avvio) | a valle dell'esperimento-incidente | P2 **o** P6 |
| **P9** demo | ❌ No (avvio) | a valle | P2/P6 + canary/blue-green |
| **P10** riallineo | ⚠️ parziale | report per-esperimento in parallelo; riallineo finale a valle | tutti |

### Cosa parte SUBITO in parallelo (giorno 1, 5 fronti su cluster diversi)
**P2 + P3 + P4 + P7** su kind separati **+** (**P5 oppure P6**) su AKS. In contemporanea, lavoro **doc senza cluster**:
pin versione (P1) · wiring token k6 + seed posti · verifica dashboard/alert Fase 4 · liste delle serie da incollare in ogni
`Observation` · **scheletro postmortem** (P8) · **storyboard demo** (P9).

### Due track concreti (chi fa cosa)
- **Track A — Infra/Chaos su AKS:** P1(AKS) → **P5** (drain) → **P6** (CNPG failover) **in sequenza** → cattura evidenze → prepara **P9** (demo). **Tiene** il cluster AKS (nessun altro inietta lì).
- **Track B — Locale/Docs su kind:** P1(kind) → **P2, P3, P4 in parallelo** (kind separati) + **P7** → riempie i report → scrive **P8** (postmortem) + scaletta **P9** → rifinisce k6.

### Punti di sincronizzazione (coordinare a voce)
- **Baseline steady-state condivisa:** stessi `VUS`/`DURATION`/`ORDERS_RATIO` + **stesso `ORDER_BODY`** (contratto pre vs post-rework) su tutti i run.
- **Chi tiene AKS e quando:** **un solo** esperimento alla volta (mai P5 e P6 insieme).
- **Quale esperimento è l'incidente** di P8 **e** P9 (deve **scattare un alert** → P2 o P6).
- **Allineamento immagine/contratto** money-path: Track A (AKS, immagine `main`) vs Track B (kind, immagine `dev`).

---

## §Prerequisiti gating (blocker — elencati, NON risolti qui)

Senza questi la prova **live su AKS** del money-path resta bloccata (i kind ne aggirano alcuni). *Owner indicato.*
1. **`global.domain` regression (PR#1):** `values.yaml` tornato al placeholder `g03.cpo2026.it` → HTTP-01 fallisce, `eurotransit-tls` non emette (`agent-log #13`). Ripristinare l'IP `*.sslip.io` corrente di Traefik. *Owner: backend/config.*
2. **`orders-oidc` secret + immagine `users` mai buildata** → `orders`/`users` non-Running su AKS → money-path live limitato. *Owner: backend.* (Su kind si aggira.)
3. **Versione Chaos Mesh** (P1/D6-B): scegliere release compatibile k8s **1.33**. *Owner: piattaforma.*
4. **Observability up** (Fase 4 ✅): ServiceMonitor scrapati, `eurotransit-checkout-slo` `health=ok`, dashboard caricate (instrument-first).
5. **k6:** token Keycloak + **seed posti** (SKU **1-posto** per P3) + **`ORDER_BODY` allineato all'immagine** (cluster gira `main`; default k6 = contratto `dev`).
6. **`az aks start -g lab02_g03_group -n lab_g03_cluster`** per i run AKS; `az aks stop` a fine sessione.

---

## §DoD locale — Fase 6 (checklist)

- ☐ **P1** Chaos Mesh installato (versione pinnata).
- ☐ **P2–P6** 5 esperimenti eseguiti sotto carico k6 (1 variabile/cluster), `Observation`+`Conclusion` riempiti.
- ☐ **P3** never-oversell sotto pod-kill+duplicati → Pillar B ☑.
- ☐ **P7** graceful degradation Notifications-down → Pillar C ☑.
- ☐ **≥1 alert burn-rate** scattato sotto guasto (P2/P6).
- ☐ **P8** postmortem blameless riempito (RTO osservato vs ≤60s).
- ☐ **P9** demo ~5 min registrata + link committato.
- ☐ **P10** docs riallineati (FASI ✅, DoD tick + Fase 4/5, agent-log #18+, design.md D9/§6.3).

---

## §Appendici

### A — Valori concreti (da `slo.md`/`design.md`)
SLO1 success-rate **≥99%**/28g · budget **1% ≈ 6.72h** · 429 non è errore (solo 5xx) · SLO2 ack **p99 ≤300ms** · SLO3 e2e **p95 ≤5s** ·
**RTO ≤60s** / **RPO=0** (P6) · burn-rate **fast 14.4×** (1h&5m) / **slow 6×** (6h&30m) ·
breaker `payments`: apre **>50% fail OPPURE >50% slow(>2s)**, window 10/min 5, wait-open 10s, 2 half-open; 4xx non apre · retry 3×200ms exp+jitter solo-transport ·
bulkhead semaforo `payments(8)`/`inventory(16)` max-wait 0 · rate-limit intake 20/s timeout 0 → **429+Retry-After** (`orders_intake_shed_total`).

### B — Teoria (deck → slide)
**deck 11** s.41 (metodo+abort+staging) · s.40/45 (observability-first) · s.42 (Chaos Mesh) · s.17–20 (CB/bulkhead) · s.22–24 (retry/backpressure) · s.32–36 (RTO/RPO/DR) · s.9–14 (replicas≠HA/PDB/topology/probe).
**deck 10** s.5 (SLI/SLO/burn-rate) · s.20 (good alert) · s.21 (RED/USE) · s.26 (telemetria checkout).
**spec** p.4–5 (5 esperimenti + output) · p.6 (postmortem+demo+DoD) · p.7 (pesi).

### C — Indice file
Manifest `platform/chaos-mesh/01..05-*.yaml` + `README.md` · report `docs/chaos/01..05-*.md` + `README.md` + `test-traceability.md` + `fase2-6-k8s-validation.md` ·
`docs/postmortem.md` · `platform/k6/money-path.js` + `README.md` · `justfile` `chaos-install`(r.362)/`loadtest`(r.374) · label `deploy/charts/eurotransit/templates/_helpers.tpl`.

### D — Ordine di esecuzione consigliato
`P1 (pin+install) → baseline k6 → [kind: P2,P3,P4,P7 in parallelo | AKS: P5 poi P6] → riempi report (P10 per-esperimento) → scegli incidente → P8 postmortem → P9 demo → P10 riallineo finale`.

---

## Verifica end-to-end (come si prova la Fase 6 una volta eseguita)

```bash
# 0. prereq: cluster su + observability + carico steady
az aks start -g lab02_g03_group -n lab_g03_cluster        # solo per i run AKS (P5,P6)
just chaos-install                                        # P1: Chaos Mesh PINNATO, ns chaos-mesh
just loadtest https://<traefik-ip>.sslip.io "$JWT"        # k6 baseline money-path (SLI live)

# 1. un esperimento alla volta PER cluster: inietta -> osserva -> revert  (es. P2)
kubectl apply -f platform/chaos-mesh/01-payments-latency.yaml
#   PromQL: resilience4j_circuitbreaker_state{name="payments"} -> OPEN ; intake ancora 202 ; Catalog RED sano
kubectl delete -f platform/chaos-mesh/01-payments-latency.yaml   # (auto-revert dopo `duration`)

# 2. P6 CNPG failover (AKS): RTO <=60s, nessuna prenotazione persa
kubectl get pods -n eurotransit -l cnpg.io/cluster=inventory-db -L role,cnpg.io/instanceRole  # verifica label
kubectl cnpg status inventory-db -n eurotransit           # prima: 1 primary + 2 sync standby
kubectl apply -f platform/chaos-mesh/05-pg-failover.yaml  # promozione standby

# 3. P5 drain (AKS): PDB rispettati, money-path mai a 0
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s
```

Esiti in `docs/chaos/0X-*.md` (Observation+Conclusion), `docs/postmortem.md`, e la **demo ~5 min linkata** nel repo.
`helm lint ./deploy/charts/eurotransit` resta **verde**: i manifest chaos vivono sotto `platform/`, **fuori** dal path che Argo
CD riconcilia (`deploy/charts/`) → **manual only, never GitOps**.
