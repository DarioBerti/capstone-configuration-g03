<!-- #DA ELIMINARE -->
> **⚠️ TO BE DELETED (#DA ELIMINARE)** — Obsolete repo guide (pre-async, sync architecture); superseded by the READMEs. Kept for now; remove in one pass when the repo is final (grep `#DA ELIMINARE`).

# Struttura della configuration repo

Se l'application repo risponde alla domanda *"come è fatto il codice?"*, la configuration repo risponde a *"cosa deve girare nel cluster, e con quali garanzie?"*. È la metà **dichiarativa** del modello a due repository: non contiene codice che si compila, ma lo **stato desiderato** del sistema. Argo CD legge questo repo e rende il cluster identico a ciò che c'è scritto qui.

```text
 dev → push su capstone-application-g03 (CODICE)
   │
   ▼  CI: testa → builda immagini immutabili :sha → push su ACR
   │            └─ aggiorna services.<svc>.image.tag in questo repo
   ▼
 capstone-configuration-g03 (STATO DESIDERATO, qui)   ← la verità in Git
   │
   ▼  Argo CD osserva deploy/charts/eurotransit
   ▼
 Cluster Kubernetes (riconciliato continuamente)
```

La CI **non parla mai col cluster** (criterio valutato): il suo unico potere è committare qui. Chiunque cambia il sistema cambiando Git.

## Le tre zone del repo

```text
 deploy/charts/eurotransit/   → COSA gira: lo stato desiderato dell'app (Helm chart)
 platform/                    → SU COSA gira: i componenti installati una volta per cluster
 docs/                        → PERCHÉ: le decisioni e i deliverable di team (judgment)
```

## Dizionario dei file

Imparati questi nomi, apri qualunque file e sai già che ruolo ha prima di leggerlo.

| File | Zona | Cosa fa | Scelta di design agganciata |
|---|---|---|---|
| `Chart.yaml` | chart | Metadati della chart (nome/versione/tipo) | Niente `dependencies` → CNPG/Strimzi sono platform-level, non subchart |
| `values.yaml` | chart | **Pannello di controllo**: immagini, repliche, db, HPA, postura di replica | È l'unico file che la CI muta (solo i tag) |
| `templates/_helpers.tpl` | chart | Snippet di label riusati (non genera risorse) | Label selector immutabili tenute separate |
| `templates/deployments.yaml` | chart | Un Deployment + Service per servizio | Probe readiness/liveness, drain SIGTERM, topology spread, secret DB |
| `templates/databases.yaml` | chart | Un `Cluster` CloudNativePG per servizio | **Database-per-service** + replica sincrona (PACELC) |
| `templates/hpa.yaml` | chart | Autoscaler solo per i servizi pubblici | HPA su catalog/orders, NO su inventory/payments |
| `templates/ingress.yaml` | chart | Ingresso Traefik + TLS | Espone **solo** Catalog e Orders (north-south) |
| `templates/poddisruptionbudgets.yaml` | chart | PDB sui servizi del money path | Disponibilità del percorso critico sotto drain |
| `platform/argocd/eurotransit-application.yaml` | platform | L'`Application` di Argo CD | **Il contratto GitOps** (prune + selfHeal = Git unica verità) |
| `platform/strimzi/kafka.yaml` | platform | Cluster Kafka KRaft (3 nodi) | Durabilità money path: RF=3 / minISR=2 |
| `platform/strimzi/kafka-topics.yaml` | platform | I 7 topic della pipeline | Partizioni = parallelismo + ordering per-ordine |
| `platform/*/README.md` | platform | Note di bootstrap (CNPG, SealedSecrets, observability, chaos) | Componenti condivisi, installati una tantum |
| `docs/design.md` | docs | Le 12 decisioni con razionale | TUTTO il "judgment" del progetto |
| `docs/agent-log.md` | docs | Gli errori dell'agente colti e corretti | Deliverable **graded** della traccia |
| `docs/*.md` | docs | DoD, SLO, threat-model, postmortem, chaos | I deliverable scritti di team |

## Generato automaticamente vs scritto a mano

Qui è netto: **ogni file è scritto a mano, NIENTE è autogenerato.** È la differenza con l'application repo (dove `build/`, `.gradle/`, `.kotlin/` erano output di build).

- Niente codice da compilare → niente `build/`.
- La chart **non ha dipendenze** → Helm non genera né `Chart.lock` né `charts/*.tgz`.
- L'output di `helm template` (il YAML finale che Argo CD applica) è **effimero**: si rigenera al volo, non si committa mai.

Quindi ogni riga di questo repo è una **scelta** che possiamo difendere all'orale!

## Come le scelte di design si agganciano ai file

Questa è la parte importante: ogni decisione architetturale "vive" in un file preciso.

- **Database-per-service** (Decisione 1) → `templates/databases.yaml` + il blocco `databases:` di `values.yaml`. Ogni servizio ha il suo `Cluster` CloudNativePG; nessuno tocca il DB di un altro. CNPG genera da solo il secret `<db>-app` con le credenziali, che `deployments.yaml` inietta nel pod (le password **non** entrano mai in Git).
- **Postura di replica = PACELC reso configurazione** (Decisione 12) → il blocco `synchronous` in `databases.yaml`. `inventory-db` è **sincrono `required`** (RPO=0 sempre, consistenza sopra disponibilità — il "never oversell" che regge anche al failover, chaos #5); `orders-db` è sincrono `preferred` (RPO=0 da sano, ma non blocca l'intake); `payments-db`/`catalog-db` single instance (la correttezza di Payments è l'idempotenza, non la replica).
- **Probe deliberate** (Pilastro C) → `deployments.yaml`. La **readiness** include il DB (toglie il pod dal traffico se il DB non c'è), la **liveness** controlla solo il processo (mai il downstream → niente restart a cascata).
- **HPA mirato** → `hpa.yaml` + i blocchi `hpa:` di `values.yaml`. Scalano solo Catalog e Orders (endpoint pubblici, carico bursty); Inventory/Payments **no**, perché il loro collo di bottiglia è il DB/PSP, non la CPU.
- **PDB + topology spread** (chaos #3) → `poddisruptionbudgets.yaml` + `topologySpreadConstraints` in `deployments.yaml`, emessi solo per i servizi `criticalPath`.
- **Degradazione controllata** di Notifications → si vede in `values.yaml`: 1 replica, niente HPA, niente PDB. È progettato per poter sparire senza rompere il checkout!
- **Eventing async durevole** → `platform/strimzi/kafka.yaml` (RF=3 / minISR=2, in coppia col producer `acks=all` del codice) e i 7 topic in `kafka-topics.yaml`.
- **GitOps senza credenziali nel cluster** (Pilastro D) → `platform/argocd/eurotransit-application.yaml`: `automated.prune` (cancella ciò che sparisce da Git) + `selfHeal` (annulla i `kubectl` manuali) = Git unica verità.
- **Segreti solo come SealedSecrets** → `platform/sealed-secrets/` + il `.gitignore` che blocca i Secret in chiaro.

## Come leggere i file (ordine consigliato)

Segui il **flusso del deploy**, non l'ordine alfabetico:

1. `README.md` (radice) — il modello a due repo + il flusso di delivery.
2. `platform/README.md` — la tabella dei componenti di cluster (il "su cosa gira").
3. `platform/argocd/eurotransit-application.yaml` — il contratto: Argo CD guarda `deploy/charts/eurotransit` e riconcilia.
4. `Chart.yaml` → `values.yaml` — il pannello di controllo (parti da qui per i parametri).
5. `templates/_helpers.tpl` — il primer di sintassi Helm (poi i template ti saranno chiari).
6. `templates/deployments.yaml` → `databases.yaml` → `ingress.yaml` → `hpa.yaml` → `poddisruptionbudgets.yaml`.
7. `platform/strimzi/kafka.yaml` → `kafka-topics.yaml` (il bus async).
8. `docs/design.md` per ultimo — lega tutto alle decisioni (consistenza/availability, PACELC).

### Esempio di flusso (un commit di Orders fino al cluster)

CI builda `eurotransit/orders:<sha>` → scrive `services.orders.image.tag` in `values.yaml` → Argo CD vede il commit → `helm template` rende i manifest → applica il Deployment di Orders (con env DB dal secret `orders-db-app` e `KAFKA_BOOTSTRAP`) → il pod parte, le probe lo dichiarano Ready → entra nel routing dell'`ingress.yaml`.

### Helm in una riga
Una chart = `Chart.yaml` (metadati) + `values.yaml` (input) + `templates/` (manifest con i "buchi"). `helm template` riempie i buchi con i valori e produce YAML puro: **un solo `range` su `.Values.services` genera tutti e 5 i Deployment**, così non c'è duplicazione.

*P.S*:
- **chart vs platform**: la `chart` è ciò che cambia spesso (l'app, deployata da Argo CD a ogni commit); `platform/` è ciò che si installa **una volta** e resta (operatori, Kafka, Argo CD stesso).
- **values.yaml è il punto di contatto col team**: per cambiare repliche, soglie HPA o postura di replica si tocca solo lì — i template non vanno riscritti.
- **docs/ non è decorazione**: `design.md` e `agent-log.md` sono deliverable valutati tanto quanto il codice. La traccia premia il *judgment*, e qui è scritto.
