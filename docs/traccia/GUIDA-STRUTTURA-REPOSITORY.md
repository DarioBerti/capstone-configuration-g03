# Guida ai repository EuroTransit (g03) — stato, contenuto, sintassi

> Aggiornata al 10/06/2026 (post Fase 1 Inventory). Spiega **cosa c'è** nelle due cartelle,
> **cosa fa ogni file**, **come si legge la sua sintassi** e come tutto si lega al sistema.
> I file più "didattici" hanno commenti inglesi inline (indicati con 📝); questa guida dà
> il quadro e i primer di sintassi per ogni linguaggio coinvolto.

## 0. Stato attuale (cosa è fatto davvero, verificato — non solo scritto)

| Pezzo | Stato |
|---|---|
| **FASE 1 COMPLETA: tutti e 5 i servizi hanno la logica di dominio** | ✅ **buildano e testano verde** (package `it.g03.<svc>`) |
| Inventory (reserve atomico, idempotenza, state machine, reconciler, eventi) | ✅ 12 test verdi (incl. 2 di concorrenza) |
| Payments (authorize **strettamente idempotente**, mock PSP, eventi) | ✅ 7 test verdi (incl. race dei duplicati: una sola charge) |
| Orders (**outbox transazionale + relay Flow + saga orchestrata** + compensazioni) | ✅ 11 test verdi (saga: happy/sold-out/declined/expired/replay; relay: ordering+retry) |
| Catalog (read API + seed allineato a inventory) | ✅ |
| Notifications (consumer fully-async + sink mock + endpoint demo) | ✅ |
| Resilience4j su Boot 4 (era il dubbio aperto #2) | ✅ verificato con asserzione sul bean `CircuitBreakerRegistry` |
| Flyway: schema reale per orders/inventory/payments/catalog (V1, + seed V2) | ✅ |
| CI GitHub Actions (matrice 5 servizi, zero cluster creds) | ✅ scritta (mai eseguita: serve il repo GitHub vero) |
| justfile standard Lab01 (`verify` a 7 passi, trap cleanup) | ✅ |
| Chart Helm (Deployment/Service/DB/Ingress/PDB/HPA + `extraEnv` per gli URL della saga) | ✅ validato con `helm lint` + `helm template` |
| Replica sincrona CNPG (postura PACELC, Decisione 12) | ✅ nel chart (richiede operatore CNPG ≥ 1.25, da verificare al bootstrap) |
| Resilienza applicativa (policy R4j, fallback PAYMENT_PENDING, 429), piattaforma su cluster, osservabilità, canary, chaos | ⬜ Fasi 2–6 |
| `docs/` (DoD, design 1–12, SLO, **agent-log con 6 voci**, threat-model) | ✅ vivi e aggiornati |

> Nota Fase 1b (nuovi file principali da leggere): in `orders/` → `Order.kt` (state machine
> dell'ordine), `OutboxEvent.kt`+`Outbox.kt`+`OutboxPublisher.kt` (pattern outbox completo),
> `OrderSaga.kt` (orchestrazione + compensazioni), `OrderStateMachine.kt` (transizioni
> transazionali — e il perché del bean separato: self-invocation pitfall di @Transactional),
> `Gateways.kt` (chiamate sync con timeout), `OrderPlacedListener.kt` (ingresso Kafka);
> in `payments/` → `PaymentsService.kt` (idempotenza stretta); in `notifications/` →
> `NotificationsListener.kt` (degradazione controllata); `EventPublishing.kt` in
> orders/inventory/payments (eventi load-bearing via outbox vs informational after-commit).

## 1. Il modello a due repository (il "perché" della struttura)

```
 dev → push su capstone-application-g03 (CODICE)
   └─ CI: testa → builda immagini immutabili :sha → push su ACR
            └─ bump dei tag in capstone-configuration-g03/values.yaml (via PAT)
                     └─ Argo CD vede il commit → riconcilia il cluster
```

Il repo **application** produce artefatti (immagini). Il repo **configuration** è la
**verità desiderata**: cosa deve girare, con quali versioni/repliche/database. Nessuno
tocca il cluster a mano: si cambia Git, Argo CD allinea. La CI **non ha mai credenziali
del cluster** (criterio di valutazione esplicito): il suo unico potere è un PAT per
committare sul config-repo.

---

# 2. `capstone-application-g03/` — il codice

## 2.1 File alla radice

| File | Cosa fa |
|---|---|
| `README.md` | porta d'ingresso: tabella servizi, stack, layout, comandi `just` |
| `justfile` | la **Local DevOps Interface** (convenzione Lab01) — primer sotto |
| `.github/workflows/ci.yml` 📝 | pipeline CI — primer sotto |
| `.gitignore` | roba OS/IDE (il build Gradle è ignorato dai `.gitignore` per-servizio) |

### Primer sintassi `justfile`
- `set shell := ["bash","-eu","-o","pipefail","-c"]` → ogni recipe gira in bash con flag
  sicuri: esci al primo errore (`-e`), variabile non definita = errore (`-u`), una pipe
  fallita fa fallire tutto (`-o pipefail`).
- `nome := "valore"` → variabile, usata come `{{nome}}`.
- `test service:` → recipe **con parametro**: `just test orders`.
- Prefisso `@` → non stampa i comandi mentre li esegue (output pulito).
- Recipe che iniziano con `#!/usr/bin/env bash` = **shebang recipe**: script unico
  multi-riga con stato condiviso (le recipe normali eseguono ogni riga in una shell
  nuova — per questo `verify`, che usa variabili e `trap`, deve essere shebang).
- 🌟 `verify <svc>` = la recipe-DoD (Lab01 Step 4): build+test → immagine → container →
  attesa readiness → health-check → **cleanup garantito** dal `trap '…' EXIT` (gira anche
  se un passo fallisce). `verify-all` la ripete su tutti i servizi.

### Primer sintassi GitHub Actions (`ci.yml`, ora commentato inline)
- `on:` = eventi trigger (push su main, `workflow_dispatch` manuale).
- I **job girano su runner separati** → si passano dati SOLO via `outputs:` letti con
  `needs.<job>.outputs.<nome>`. È il motivo della struttura a 3 job.
- `${{ … }}` = espressioni; contesti: `github`, `needs`, `matrix`, `steps`, `env`,
  `secrets` (cifrati: `ACR_*`, `CONFIG_REPO_PAT`), `vars` (in chiaro: `GITOPS_REPO`).
- `strategy.matrix` = un job **parallelo** per elemento della lista; `fromJSON(...)`
  converte la stringa JSON in lista vera.
- Flusso: **detect-changes** (dorny/paths-filter → quali `services/<svc>/**` sono cambiati,
  emette lista JSON) → **build** (matrice: `gradlew test`, login ACR, build+push `:sha`
  immutabile + `:latest`) → **update-gitops** (checkout config-repo col PAT, `yq` riscrive
  `services.<svc>.image.tag`, commit come github-actions[bot], niente commit vuoti).
- Nota (TODO nel file): il codice si compila due volte (test in CI + build nel Dockerfile);
  pattern dei Lab, tenuto per coerenza.

## 2.2 Anatomia comune di un servizio (`services/<svc>/`)

Ogni servizio è un'app Spring Boot **autosufficiente** (proprio wrapper Gradle + proprio
Dockerfile) così la CI lo builda in isolamento.

| File | Cosa fa / come si legge |
|---|---|
| `build.gradle.kts` | dipendenze e plugin. **Quello di `orders` è l'esemplare annotato** 📝: `plugin.spring` apre le classi `final` di Kotlin perché Spring crea proxy per sottoclasse (è così che funziona `@Transactional`); `plugin.jpa`+`allOpen` generano no-arg ctor e aprono le `@Entity` per i lazy-proxy di Hibernate; `dependency-management` importa il **BOM** di Boot (ecco perché le dipendenze non hanno versione). Gli altri 4 cambiano solo il set di dipendenze, tarato sul ruolo. |
| `settings.gradle.kts` | solo `rootProject.name` |
| `Dockerfile` 📝 (annotato in orders) | **multi-stage**: stage builder con JDK compila il fat-jar (`-x test`: i test girano in CI *prima*); stage runtime = solo JRE + jar → immagine piccola, niente toolchain in prod; `USER app` **non-root** (igiene Lab01) |
| `.dockerignore` | esclude `build/`, `.gradle/`, `.git/` dal contesto docker (Lab01 Step 3) |
| `application.yml` 📝 | profilo default (dev locale): **H2 in-memory** (zero dipendenze), `ddl-auto: update`, Flyway spento; blocco `kafka` commentato (vedi sotto); blocco `management` (vedi sotto) |
| `application-postgres.yml` | profilo `postgres` (in cluster): datasource da env `DB_*` (iniettate dal Secret CNPG), **Flyway acceso** (possiede lo schema), `ddl-auto: validate` (Hibernate verifica soltanto) |
| `db/migration/V<N>__nome.sql` | migrazioni Flyway: eseguite in ordine, una volta sola (registro `flyway_schema_history`). Inventory ha schema vero (V1) + seed (V2); gli altri placeholder |
| `<Svc>Application.kt` | entry point `@SpringBootApplication` |
| test | `contextLoads` ovunque; orders ha l'**asserzione Resilience4j**; inventory la suite completa |

### Blocco `kafka` (dove c'è; commentato nei file)
- `${KAFKA_BOOTSTRAP:localhost:9092}` = placeholder Spring "*env var se c'è, altrimenti default*".
- Producer: `acks=all` (attende le repliche in-sync, in coppia col `min.insync.replicas=2`
  del broker) + `enable.idempotence` (il broker scarta i duplicati creati dai retry del producer).
- Consumer: `enable-auto-commit: false` → **commit manuale dell'offset solo dopo aver
  processato** = consegna **at-least-once** = gli handler devono essere idempotenti (e lo sono by design).

### Blocco `management` (uguale ovunque — scelta valutata all'orale)
- **readiness** (`/actuator/health/readiness`) = "posso servire ORA?" → include il *proprio*
  DB, **esclude Kafka** (un blip del broker non deve togliere i pod dal load balancer).
- **liveness** (`/actuator/health/liveness`) = "il processo è vivo?" → **mai** dipendenze
  esterne, altrimenti un guasto a valle causa restart a cascata (anti-pattern citato dalla traccia).
- `/actuator/prometheus` = metriche per le dashboard RED; `management.otlp.tracing.endpoint`
  = dove spedire le trace (sovrascritto in cluster via env).

## 2.3 Inventory — il codice implementato (walkthrough + primer Kotlin/Spring)

Il cuore del Pilastro B, **12 test verdi**. Tutti i file sono già commentati in inglese.

**`InventoryItem.kt`** — entità della risorsa contesa. `@Entity`/`@Table` = riga di tabella,
`@Id` = chiave; `data class` genera equals/hashCode/toString; ctor vuoto per JPA (stile Lab04).
Regola di design: **`available` non si tocca mai via entity** (leggi-modifica-salva su un
contatore = lost-update garantito) — solo UPDATE atomici dal repository.

**`Reservation.kt`** — la **state machine**: `RESERVED → CONFIRMED | RELEASED | EXPIRED`,
più `REJECTED` (sold-out). Dettaglio architetturale: `UNIQUE(order_id, product_id)` rende
la riga di prenotazione **anche il record di idempotenza** (niente tabella dedup separata).

**`InventoryItemRepository.kt`** — il file più importante:
- le interfacce `JpaRepository` ricevono l'implementazione **gratis** da Spring Data;
- `tryDecrement` = `@Modifying @Query("update … set available = available - :qty where …
  and available >= :qty")` → **l'UPDATE condizionale atomico**: il row-lock serializza i
  concorrenti, il perdente vede 0 righe = sold out. Il "never oversell" eseguibile;
- `flushAutomatically = true` è la cicatrice del **bug reale** trovato dai test (agent-log
  #6): senza, `clearAutomatically` buttava le transizioni di stato non flushate → doppio restock.

**`ReservationRepository.kt`** — query derivate dal nome (`findByOrderIdAndProductId` →
Spring Data genera il WHERE dal nome del metodo).

**`InventoryService.kt`** — logica transazionale:
- `@Transactional` = Spring apre/commit/rollback attorno al metodo, via proxy;
- `reserve()`: pre-check replay → decremento atomico → save prenotazione, **una sola
  transazione**. Caso sottile (commentato): due duplicati *concorrenti* dello stesso ordine
  decrementano entrambi, ma solo uno inserisce la riga (UNIQUE) → l'altro rollbacka
  **incluso il suo decremento**. Un commit, un decremento; il perdente viene rigiocato
  dalla redelivery e finisce nel replay;
- `confirm()`: race "pagamento lento vs TTL scaduto" (raffinamento #3): TTL passato →
  `EXPIRED` + restock, mai confermare un posto non più tenuto;
- `release()`: compensazione della saga, idempotente;
- counter Micrometer `inventory_reservations_total{outcome=…}` → metrica business per le SLI.

**`ReservationReconciler.kt`** — il Pilastro A in miniatura:
- `CoroutineScope(SupervisorJob() + Dispatchers.Default)` = **failure domain**: uno sweep
  fallito non uccide il loop;
- `while (isActive) { delay(…); sweep() }` + `destroy()` → `scope.cancel()` =
  **cancellazione cooperativa su SIGTERM** (nei log dei test: *"cancelling reservation
  reconciler (cooperative shutdown)"*). Senza reconciler, una saga crashata tra reserve e
  confirm incaglierebbe posti per sempre.

**`InventoryController.kt`** — API REST **interna** (non esposta dall'ingress):
`POST /api/inventory/reservations`, `…/confirm`, `…/release`, `GET /api/inventory/items/…`.
Scelta documentata: **sold-out = 200 con campo `status`**, non errore HTTP — è una risposta
di business su cui la saga decide; un 4xx/5xx farebbe scattare retry e circuit breaker del
chiamante per un non-guasto.

**Test** — `InventoryServiceTest` (9 casi: decremento, sold-out, replay con un solo
decremento, outcome immutabile dopo restock, confirm/release idempotenti, race TTL, sweep,
404) e `InventoryConcurrencyTest` (le 2 prove: *8 thread sull'ultimo posto → esattamente 1
vincitore*; *8 duplicati dello stesso ordine → 1 solo decremento*).

---

# 3. `capstone-configuration-g03/` — lo stato desiderato

## 3.1 Primer sintassi Helm (vale per tutti i template)
- Un chart = `Chart.yaml` (metadati) + `values.yaml` (input) + `templates/` (manifest con
  "buchi"). `helm template` riempie i buchi e produce YAML puro che Argo CD applica.
- `{{ .Values.x.y }}` legge dal values; `{{- … }}` mangia spazi/righe vuote.
- `range $name, $svc := .Values.services` = ciclo sulla mappa → **un template solo genera
  i 5 Deployment**. Dentro al `range` il punto (`.`) viene ri-legato: per questo gli helper
  ricevono un contesto esplicito `(dict "svc" $name "root" $)` — `$` è sempre la radice.
  Spiegato per esteso nei commenti di `templates/_helpers.tpl` 📝.
- `include "nome" ctx | nindent 4` = renderizza l'helper come stringa e la indenta
  (YAML è sensibile agli spazi).
- `dig "hpa" "enabled" false $svc` = accesso sicuro con default (non esplode se manca la chiave).

## 3.2 `deploy/charts/eurotransit/` file per file

| File | Cosa genera | Punti chiave |
|---|---|---|
| `Chart.yaml` | metadati | commento: perché NIENTE subchart CNPG (deviazione documentata dal Lab04: l'operatore è platform-level, i DB sono CR nel chart) |
| `values.yaml` 📝 | l'input di tutto | **il file più commentato del progetto**: per ogni servizio repliche/db/criticalPath/hpa col *perché*; per ogni database la **postura di replica** (sotto); unico file mutato dalla CI (solo i tag) |
| `templates/deployments.yaml` | 5 Deployment + 5 Service | probe readiness/liveness separate; env condizionali (`DB_*` dal secret `<db>-app` CNPG se `db`, `KAFKA_BOOTSTRAP` se `usesKafka`, endpoint OTLP sempre); `topologySpreadConstraints` se criticalPath; **`replicas` omesso quando l'HPA è acceso** (sennò Argo CD e HPA si fanno la guerra sul numero); `terminationGracePeriodSeconds: 30` + `preStop sleep 5` = finestra di drain (Pillar A) |
| `templates/databases.yaml` | 4 Cluster CNPG | blocco `synchronous` opzionale (Decisione 12, sotto); CNPG genera da solo il secret `<db>-app` consumato dai Deployment; PodMonitor acceso; `resource-policy: keep` (i dati sopravvivono alla rimozione del release) |
| `templates/hpa.yaml` | HPA per catalog+orders | perché inventory/payments NON scalano: il collo di bottiglia è DB/PSP, non CPU — più repliche non aumentano il throughput |
| `templates/ingress.yaml` | Ingress Traefik+TLS | espone SOLO `/api/catalog` e `/api/orders`; Inventory/Payments/Notifications restano interni |
| `templates/poddisruptionbudgets.yaml` | PDB sui critical-path | `minAvailable: 1`, emesso solo con ≥2 repliche (protegge dai drain volontari, chaos #3) |
| `templates/_helpers.tpl` 📝 | label comuni | con primer di sintassi inline; selector labels separate (i selector sono immutabili) |

### La postura di replica (Decisione 12 — consistenza vs availability resa configurazione)
- **inventory-db**: 3 istanze, replica **SINCRONA** `dataDurability: required` → RPO=0
  sempre; primary isolato = scritture bloccate (il nostro PACELC **PC/EC** reso reale).
  Perché: la replica **asincrona di default può perdere transazioni committate sul
  failover** → una prenotazione sparirebbe e il posto verrebbe rivenduto (agent-log #5).
  Con 3 istanze (ANY 1 di 2 standby) la perdita di UNA replica non blocca le scritture.
- **orders-db**: 2 istanze, sincrona `preferred` → RPO=0 da sano, degrada ad async invece
  di bloccare l'accettazione ordini (gli invarianti non vivono in orders-db).
- **payments-db / catalog-db**: 1 istanza (decisione team 09/06): la correttezza di
  Payments la fa l'**idempotenza**, non la replica; il guasto lo contiene il circuit breaker.
- Richiede CNPG ≥ 1.25 (annotato nel chart, da verificare al bootstrap).

## 3.3 `platform/` — installato una volta per cluster

| Path | Contenuto |
|---|---|
| `README.md` | tabella dei componenti piattaforma (Traefik, cert-manager, CNPG, Strimzi, Sealed Secrets, Argo CD, kube-prometheus-stack, Tempo/OTel, Chaos Mesh) con namespace e ruolo |
| `argocd/eurotransit-application.yaml` 📝 | l'`Application` Argo CD, **commentata campo per campo**: `source` (quale repo/path/branch), `destination`, `automated.prune` (cancella ciò che sparisce da Git) + `selfHeal` (annulla i kubectl manuali) = Git unica verità; finalizer = cascade delete; `ServerSideApply` per i CRD grossi |
| `strimzi/kafka.yaml` | Kafka **KRaft** (niente ZooKeeper), 3 nodi dual-role = minimo per il quorum; RF=3/`min.insync.replicas=2` per la durabilità del money path; **risorse limitate** (heap 512m): "right-size, don't shrink HA" |
| `strimzi/kafka-topics.yaml` | i 7 topic: `order-placed`, `inventory-reserved`, `inventory-released`, `payment-authorized`, `order-confirmed`, `order-rejected`, `notification-requested` |
| `cloudnativepg/`, `sealed-secrets/` | README di bootstrap (operatore CNPG; come sigillare un secret — in Git SOLO SealedSecrets) |
| `observability/README.md` | **decisioni pinnate** (Decisione 11): Tempo (non Jaeger), OTel Collector gateway, dashboard RED/USE/Kafka-lag/CNPG as code, SOLO alert burn-rate multi-finestra, log JSON con traceId, sampling 100% |
| `chaos-mesh/README.md` | i 5 esperimenti pianificati con i nomi dei manifest |

## 3.4 `docs/` — deliverable valutati

| File | Stato |
|---|---|
| `design.md` | decisioni **1–12** con razionali; D1 risolta (feedback team 09/06); D12 = postura di replica; aperte: D2 (auth), D9 (Argo Rollouts?), variante D12 (3 vs 2 istanze inventory) |
| `capstone-dod.md` | checklist DoD per pilastro (da spuntare man mano) |
| `slo.md` | SLO draft (success-rate ≥99%, ack p99 ≤300ms, e2e p95 ≤5s) + **dove si misura ogni SLI**: ack a Traefik (verità edge), e2e/success-rate come **metriche business emesse da Orders** (solo lui vede la state machine; non derivabili da metriche HTTP perché il flusso attraversa Kafka) |
| `agent-log.md` | **6 voci** (ne servivano ≥3): 1 Helm-in-plain-yaml ✓ · 2 R4j/Boot4 ✓ **risolta con prova** · 3 probe (watch, da validare sotto chaos) · 4 justfile sotto standard Lab01 ✓ · 5 replica async vs claim CP ✓ · 6 clearAutomatically/doppio restock ✓ (beccata dai test) |
| `agent-threat-model.md` | blast radius dell'agente nel control loop (least privilege, review gate, worst case) |
| `postmortem.md`, `chaos/README.md` | template pronti per le fasi finali |

---

# 4. Come si legge il sistema a runtime (quando sarà completo)

1. `POST /api/orders` → Traefik → Orders: salva ordine `PENDING` + evento nella **outbox**
   (stessa transazione) → risponde **202** con l'orderId.
2. Poller coroutine legge la outbox → pubblica `order-placed` su Kafka (at-least-once).
3. Consumer di Orders → chiama **sync** `Inventory.reserve` (✅ già implementato: UPDATE
   atomico + idempotenza) → `RESERVED` o `REJECTED` (→ compensazione).
4. Orders → chiama **sync** `Payments.authorize` dietro circuit breaker/retry+jitter/
   bulkhead, con idempotency key (mai un hang illimitato).
5. `CONFIRMED` → eventi `order-confirmed` + `notification-requested` → Notifications
   consuma (e può essere **completamente giù** senza rompere il checkout).
6. Tutto emette metriche RED + trace OTel (contesto propagato negli header Kafka) + le
   metriche business per gli SLO.

Sottigliezza da orale: le chiamate sync a Inventory/Payments avvengono **dentro** la
pipeline async — l'API HTTP ritorna subito, ma gli stadi successivi fanno chiamate sincrone
perché lì serve una decisione immediata.

# 5. Cosa manca (in ordine)

1. **Fase 1b**: contratti eventi Kafka; **Payments** (authorize idempotente — piccolo,
   propedeutico); **Orders** (outbox + poller + pipeline consumer — il pezzo grosso);
   Catalog; Notifications.
2. **Fase 2**: policy Resilience4j (open/half-open, fallback) + test funzionale del circuit
   breaker; backpressure/429.
3. **Fase 3**: bootstrap piattaforma su cluster reale + CI collegata ai repo GitHub.
4. **Fase 4**: osservabilità (kube-prometheus-stack, Tempo/OTel, dashboard, alert burn-rate).
5. **Fase 5**: canary (TraefikService) + blue/green.
6. **Fase 6**: i 5 chaos experiment + postmortem + demo registrata.
