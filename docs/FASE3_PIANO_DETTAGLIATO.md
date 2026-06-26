# Fase 3 — Piattaforma sul cluster reale: piano tecnico dettagliato

> Documento di lavoro del team. Porta il sistema da "tutto locale + chart validata con `helm template`"
> a **gira davvero su un cluster Kubernetes reale (Azure AKS)**, riconciliato da Argo CD.
> Ancorato ai file già esistenti (chart, `platform/`, CI) e ai Lab 03/04. Generato il 2026-06-26.
> Complementare a `traccia/FASI_PROGETTO.md` (Fase 3) e a `FASE2_PIANO_DETTAGLIATO.md` (app repo).

**Stack di riferimento:** AKS (cluster) · ACR (registry, già citato come `lab02g03registry.azurecr.io`) ·
Argo CD (GitOps) · Traefik + cert-manager (ingress/TLS) · CloudNativePG (DB) · Strimzi (Kafka) ·
Sealed Secrets. Tutto già **descritto** in `platform/` — la Fase 3 lo **installa e lo fa funzionare**.

---

## DECISIONI (7 prese il 2026-06-26 ✅ · 1 ancora aperta ⏳)

Le scelte non ovvie del piano. Le sette **D-A..D-G** sono confermate; **D9** è l'unica ancora da decidere
(ma è roba di Fase 5, non blocca il bootstrap). Ogni riga è richiamata puntualmente nelle sezioni sotto.

| # | Decisione | Scartata | Perché | Dove |
|---|---|---|---|---|
| **D-A** | ✅ **Un solo cluster AKS condiviso** dal gruppo, con **ogni membro aggiunto come collaboratore con privilegi admin** | Uno per persona | Il budget (~200€/persona) si brucerebbe in parallelo inutilmente; un cluster solo = più credito per tenerlo su nei giorni di lavoro/demo, e tutti possono operarci | §1 |
| **D-B** | ✅ **`az aks stop` quando non si lavora** (spegnere i nodi, non distruggere) | Lasciarlo acceso / distruggerlo ogni volta | È **la** decisione che fa stare il progetto nei 200€. Acceso h24 brucia ~8€/giorno; spento paghi solo i dischi (centesimi) | §1.4, Appendice A |
| **D-C** | ✅ **2 nodi `Standard_B4ms`** (4 vCPU/16 GB) per il lavoro quotidiano; **scalare a 3 SOLO per i chaos experiment (Fase 6) e la demo finale** | Nodi più grossi D-series / 1 nodo / 3 fissi | I requests stimati stanno in ~3.3 vCPU/9 GiB: 2 nodi bastano e costano meno; il 3° serve solo quando topology spread + PDB + chaos node-kill devono essere *dimostrati*. B-series è la più economica | §1.3 |
| **D-D** | ✅ **Opzione A: piattaforma installata a mano con `helm`/`kubectl`; SOLO l'app `eurotransit` passa da Argo CD** | App-of-apps (anche la piattaforma in GitOps) | La traccia chiede *l'app* Synced & Healthy. App-of-apps è over-engineering per ora; gli operatori sono "install once" come dice `platform/README.md` | §2, §5 |
| **D-E** | ✅ **TLS con hostname "IP-based" gratuito (`sslip.io`/`nip.io`) + Let's Encrypt**, non un dominio comprato | Comprare `g03.cpo2026.it` (placeholder nel chart) | Evita spesa e gestione DNS; HTTP-01 di Let's Encrypt funziona contro l'IP pubblico di Traefik. `g03.cpo2026.it` nel chart è **finto** | §3.2 |
| **D-F** | ✅ **Pull da ACR via managed identity** (`az aks update --attach-acr`), niente `imagePullSecret` | imagePullSecret sealed in Git | Più pulito e meno segreti in giro; è il modo "Azure-native". Nessuna modifica al chart richiesta | §1.2, §4 |
| **D-G** | ✅ **Riuso dell'ACR `lab02g03registry` (esistente e attivo)** — è il registry/cluster di Dario, con gli altri membri già aggiunti come collaboratori admin | ACR nuovo | È già hard-coded in `values.yaml` e nella CI → **zero modifiche**; esiste già e il gruppo vi ha accesso | §1.2 |
| **D9** | ⏳ **DA DECIDERE** — strategia di canary: **solo `TraefikService`** *oppure* anche **Argo Rollouts**. Viene da `docs/design.md` (decisione 9) / "decisioni aperte" di `FASI_PROGETTO.md`. **Si decide in Fase 5**, non ora | — | Impatto su Fase 3: se sceglierete Argo Rollouts dovrete installare **il suo controller come operatore extra** in §2; se restate su `TraefikService` **niente di nuovo** (Traefik è già installato). **Non blocca il bootstrap** | §2 (eventuale), §5 |

> Le sette decisioni ✅ sono confermate: annotarle in `docs/design.md` (anche una riga ciascuna) — è lì che
> si prende il voto. **D9 è l'unica ancora aperta** ma è una scelta di Fase 5: per la Fase 3 si può ignorare,
> al più aggiunge un operatore in §2 se in futuro si opta per Argo Rollouts. La **variante D12** (inventory-db
> 3 vs 2 istanze) **non** è aperta: **resta a 3, come già scelto nel chart**, nessuna azione (vedi §1.3).

---

## 1. Provisioning Azure (cluster + registry)

Obiettivo: avere un cluster AKS raggiungibile via `kubectl` e capace di **pullare** le immagini private da ACR.

### 1.1 — Risorse base (D-A: cluster unico condiviso)
- Cosa: creare un **resource group** dedicato (es. `rg-eurotransit-g03`) in una region vicina (`westeurope`).
  **Un solo cluster per tutto il gruppo** (D-A); aggiungere ogni membro come **collaboratore con ruolo admin**
  (es. `Azure Kubernetes Service Cluster Admin Role` sul cluster / accesso al resource group) così tutti
  possono operarci.
- ⚙️ Comandi (Appendice A). Il **control plane AKS è gratis** in tier Free → si paga solo il node pool.
- ☑️ `az group create` ok; `az aks create` completa; `az aks get-credentials` scrive il kubeconfig; ogni
  membro riesce a fare `kubectl get nodes`.

### 1.2 — Registry immagini (ACR) — D-G, D-F (confermate)
- Cosa: **riusare `lab02g03registry.azurecr.io`** — esiste, è il registry di Dario e gli altri membri sono
  già collaboratori admin (D-G). È già in `values.yaml:7` e in `ci.yml` → **nessuna modifica ai file**.
- Cosa: dare ad AKS il diritto di pull con `az aks update --attach-acr lab02g03registry` (managed identity,
  D-F). **Niente `imagePullSecret`** → nessun segreto in più, nessuna modifica al chart.
- ☑️ `az acr login` ok; un `kubectl run` con un'immagine del registry parte senza ImagePullBackOff.

### 1.3 — Sizing del node pool — D-C (confermata: 2 di default, 3 per chaos/demo)
- Cosa: 1 node pool Linux. **Stima dei requests** (CPU/mem garantiti, da `values.yaml` + `platform/`):
  - app: 9 pod × 100m/256Mi ≈ **0.9 vCPU / 2.3 GiB**
  - Postgres CNPG: catalog 1 + orders 2 + inventory 3 + payments 1 = 7 pod × 100m/256Mi ≈ **0.7 vCPU / 1.8 GiB**
  - Kafka Strimzi: 3 nodi × 250m/768Mi ≈ **0.75 vCPU / 2.3 GiB**
  - operatori + Argo CD + Traefik + cert-manager + sealed-secrets ≈ **1–1.5 vCPU / 2–3 GiB**
  - **Totale ≈ 3.3–3.6 vCPU / ~9 GiB di soli requests** (senza Fase 4 observability, che aggiunge parecchio).
- Scelta confermata (D-C): **2× `Standard_B4ms`** (4 vCPU/16 GB ciascuno → 8 vCPU/32 GB) per il lavoro
  quotidiano — fitta tutto con margine e tollera la perdita di 1 nodo. **Si scala a 3 SOLO quando servono
  i chaos experiment (Fase 6) e per la demo finale** (`az aks scale -g $RG -n $AKS --node-count 3`), perché
  topology spread / PDB / chaos node-kill diventano *dimostrabili* solo con 3 nodi; finita la sessione, di
  nuovo a 2 (o `az aks stop`). B-series (burstable) è la più economica per un cluster non sempre sotto carico.
- ✅ **Variante D12 — confermato 3 istanze per inventory-db (nessun cambiamento rispetto alla scelta già
  fatta nel chart).** L'alternativa a 2 istanze risparmierebbe 1 pod Postgres (~256Mi) ma bloccherebbe le
  scritture se l'unica standby cade → si resta sui **3** già presenti in `values.yaml:147-156` (più sicuro,
  costo trascurabile, nessuna modifica al chart). È una scelta di consistenza, non di costo.
- ☑️ `kubectl get nodes` mostra i nodi `Ready`; `kubectl describe node` mostra Allocatable sufficiente.

### 1.4 — Controllo costi — D-B (confermata: LA decisione che fa stare nei 200€)
- Cosa: **spegnere il cluster quando non si lavora** con `az aks stop` (dealloca i nodi: si paga solo lo
  storage dei dischi, pochi centesimi/giorno) e `az aks start` per riprendere. Acceso 24/7 brucia ~8€/giorno.
- ⚙️ Mettere i due comandi nel `README` di `platform/` o in un piccolo `justfile`/script (Appendice A).
- ☑️ Dopo `az aks stop` il portale mostra i nodi *Stopped*; il credito smette di scendere sul compute.

---

## 2. Bootstrap operatori di piattaforma (ordine = dipendenze) — D-D (Opzione A)

Obiettivo: installare gli operatori **prima** che Argo CD provi a sincronizzare l'app, altrimenti i CRD
(`Cluster` CNPG, `Kafka` Strimzi) non esistono e il sync fallisce. **Install once**, a mano con `helm`/`kubectl`.

**Ordine consigliato** (ognuno nel suo namespace, come da `platform/README.md`):

1. **cert-manager** (`cert-manager`) — serve i certificati TLS dell'ingress. Installa anche i suoi CRD.
2. **Traefik** (`traefik`) — ingress controller + IngressClass. È l'edge del money-path.
3. **Sealed Secrets controller** (`kube-system`) — così i `SealedSecret` in Git diventano `Secret` reali.
4. **CloudNativePG operator** (`cnpg-system`) — ⚠️ **versione ≥ 1.25** (richiesta dalla `postgresql.synchronous`
   di inventory/orders, vedi `values.yaml:123` e nota replica). Comando già in `platform/cloudnativepg/README.md`.
5. **Strimzi operator** (`kafka`) — reconcilia `Kafka`/`KafkaTopic`/`KafkaUser`.
6. **Argo CD** (`argocd`) — installato per ultimo: è lui che poi prende in carico l'app.

- 📘 Razionale d'ordine: gli operatori **registrano i CRD**; i CR (Kafka cluster, Postgres Cluster) che il
  chart e `platform/strimzi/` dichiarano devono trovare i CRD già presenti. cert-manager/Traefik prima
  perché l'ingress dell'app li richiede al primo sync.
- ☑️ `kubectl get pods -A` → tutti gli operatori `Running`; `kubectl get crd | grep -E 'cnpg|kafka|cert-manager'`
  mostra i CRD attesi.

> **Versioni:** pinnate la versione di ogni chart/manifest operatore (no `latest`) e annotatela in
> `platform/README.md`. È la stessa igiene del Lab04 (immagini immutabili → operatori riproducibili).

---

## 3. CR di piattaforma + TLS

Obiettivo: portare su Kafka e l'emissione certificati, che il chart dell'app dà per scontati.

### 3.1 — Kafka cluster + topic (Strimzi)
- Cosa: applicare `platform/strimzi/kafka.yaml` (cluster KRaft 3 nodi, RF=3/minISR=2 — **già scritto**) e
  `platform/strimzi/kafka-topics.yaml` (i 7 topic). Pinnare la versione Strimzi (oggi il file fissa già
  Kafka `3.9.0`).
- 🔁 Il bootstrap interno `eurotransit-kafka-bootstrap.kafka.svc:9092` combacia con `values.yaml:12`
  (`global.kafkaBootstrap`) → i servizi `usesKafka` lo ricevono via env. Nessuna modifica al chart.
- ☑️ `kubectl get kafka,kafkatopic -n kafka` → cluster `Ready`, 7 topic creati.

### 3.2 — Ingress TLS — D-E (confermata: hostname IP-based gratuito)
- Cosa: creare un `ClusterIssuer` cert-manager (Let's Encrypt; **prima `staging`** per non bruciare il rate
  limit, poi `prod`). Decidere l'hostname pubblico.
- ⚠️ `values.yaml:9` ha `domain: g03.cpo2026.it` che è un **placeholder**. Due strade:
  1. **(consigliata) `sslip.io`/`nip.io`:** usi l'IP pubblico di Traefik come hostname
     (`<IP>.sslip.io`) → zero acquisto DNS, Let's Encrypt HTTP-01 funziona. Aggiorni `global.domain` con
     questo nome.
  2. Comprare/usare un dominio vero e puntare un record A all'IP di Traefik.
- 🔁 `templates/ingress.yaml` espone **solo** `/api/catalog` e `/api/orders`; Inventory/Payments/Notifications
  restano interni. Il certificato viene emesso per `global.domain`.
- ☑️ `kubectl get certificate` → `Ready=True`; `curl https://<host>/api/catalog/...` risponde con TLS valido.

---

## 4. Secrets — D-F (confermata: pull via managed identity)

Obiettivo: capire **quali** segreti servono davvero (spoiler: pochissimi, by design).

- **Credenziali DB:** **non servono segreti in Git.** CNPG genera da solo il `<db>-app` Secret in-cluster,
  che il Deployment consuma via `secretKeyRef` (`deployments.yaml:74-99`). Già verificato nel chart:
  il profilo `postgres` e le `DB_*` sono cablati correttamente.
- **Pull da ACR:** gestito dalla managed identity (§1.2) → niente `imagePullSecret`.
- **Quando serve un `SealedSecret`:** solo se introdurrete un segreto applicativo (es. un token PSP reale —
  ora il PSP è mock). In quel caso seguite `platform/sealed-secrets/README.md` (`kubeseal`) e committate
  **solo** il SealedSecret.
- ☑️ Nessun `Secret` in chiaro in Git (lo `.gitignore`/policy del Lab04 lo enforce); i pod dell'app partono
  con le `DB_*` iniettate.

> **Conclusione:** per la Fase 3 *as is* probabilmente **non devi sigillare nulla**. Documenta questo fatto
> (è una proprietà di design, non una dimenticanza).

---

## 5. Argo CD: portare l'app a **Synced & Healthy** — D-D (il cuore della Fase 3)

Obiettivo: l'`Application` Argo CD riconcilia il chart dal config-repo e raggiunge **Synced & Healthy**.

### 5.1 — Allineare l'`Application` al repo reale
- Cosa: `platform/argocd/eurotransit-application.yaml` punta a
  `repoURL: https://github.com/DarioBerti/capstone-configuration-g03.git`, `targetRevision: main`,
  `path: deploy/charts/eurotransit`. **Verificare che questo sia l'URL GitHub vero del config-repo del
  gruppo** (org/owner corretto). Se il repo è privato, registrare le **repo creds** in Argo CD
  (idealmente come SealedSecret, come anticipa `platform/README.md`).
- ☑️ `kubectl apply -f platform/argocd/eurotransit-application.yaml` crea l'Application in ns `argocd`.

### 5.2 — Primo sync
- Cosa: con `automated.prune + selfHeal` già impostati, Argo CD sincronizza da solo. `CreateNamespace=true`
  crea `eurotransit`; `ServerSideApply=true` gestisce i CRD grossi (Cluster CNPG).
- 📘 Ordine interno: Argo applica i Cluster CNPG → l'operatore crea i Postgres e i Secret `<db>-app` →
  i Deployment partono e leggono quei Secret. Se i pod app vanno in `CreateContainerConfigError` un attimo,
  è perché il Secret CNPG non è ancora pronto: si risolve da solo al reconcile successivo (è atteso).
- ☑️ Argo CD UI/`argocd app get eurotransit` → **Synced** e **Healthy**; `kubectl get pods -n eurotransit`
  → tutti Running/Ready.

### 5.3 — Prova drift + reconcile (richiesto dalla traccia)
- Cosa: fare una modifica "fuori banda" con `kubectl` (es. `kubectl scale deploy/catalog --replicas=5`) e
  osservare **selfHeal** che la annulla; rimuovere una risorsa e vedere che torna; cambiare un tag in Git e
  vedere il rollout.
- 📘 Dimostra che **Git è l'unica verità** (Lab04): nessuno modifica il cluster a mano.
- ☑️ Screenshot/log del self-heal per la demo (Fase 6) e una riga in `docs/`.

---

## 6. Verifiche specifiche della Fase 3

Le cose che la traccia (`FASI_PROGETTO.md` §Fase 3) chiede di **provare**, non dichiarare:

- **6.1 Replica sincrona CNPG:** `kubectl get cluster -n eurotransit` → inventory-db 3 istanze,
  orders-db 2, con stato `synchronous` atteso. Verificare che una `kubectl cnpg status inventory-db` mostri
  la replica sincrona attiva (RPO=0). 📘 È la Decisione 12 resa reale (PACELC PC/EC).
- **6.2 Secret `<db>-app` iniettati:** `kubectl exec` in un pod orders → le env `DB_HOST/DB_NAME/...` sono
  popolate dal Secret CNPG; l'app è sul profilo `postgres` (non H2).
- **6.3 Health del money-path:** un `POST /api/orders` reale attraversa Traefik→Orders→outbox→Kafka→
  Inventory/Payments→CONFIRMED. (Se 2.6/2.7 non ancora mergiati, il path funziona comunque; mancano solo le
  metriche/anti-storm extra.)
- **6.4 (sblocca Fase 2 §6):** con il cluster su, il team Fase 2 valida live probe/PDB/HPA/topology/
  graceful-degradation (Notifications giù → checkout OK). Qui la Fase 3 si limita a **rendere possibile**
  quella prova.

> **Gotcha noto (non bloccante):** i Deployment puntano l'OTLP tracing a
> `otel-collector.observability.svc:4318` (`deployments.yaml:58-59`), che **non esiste fino alla Fase 4**.
> L'export delle trace fallirà silenziosamente (fire-and-forget) — **non** fa crashare l'app. Opzioni:
> (a) accettare gli errori di export fino alla Fase 4; (b) deployare un collector no-op ora. Consiglio (a):
> non over-engineerare, è un warning innocuo.

---

## 7. Collegare la CI ai repo GitHub veri

Obiettivo: chiudere l'anello GitOps — `git push` sull'app-repo → immagini in ACR → bump tag nel config-repo
→ Argo CD riconcilia. La CI è **già scritta** (`ci.yml`), mai eseguita: serve configurare i segreti/variabili.

Da impostare nelle **Settings → Secrets/Variables** del repo `capstone-application-g03`:

| Nome | Tipo | Valore | Usato in `ci.yml` |
|---|---|---|---|
| `ACR_USERNAME` | secret | admin user dell'ACR (o service principal) | login ACR |
| `ACR_PASSWORD` | secret | password/token ACR | login ACR |
| `CONFIG_REPO_PAT` | secret | **PAT con write SOLO sul config-repo** (least privilege) | checkout + push gitops |
| `GITOPS_REPO` | variable | `DarioBerti/capstone-configuration-g03` (owner/repo reale) | checkout config-repo |

- 📘 **Vincolo di valutazione esplicito:** la CI **non ha mai credenziali del cluster**. Il suo unico potere
  è il PAT sul config-repo. Verificare che nessun secret del cluster finisca nel workflow.
- 🔁 Allineare `env.REGISTRY`/`IMAGE_PREFIX` in `ci.yml` con l'ACR scelto in §1.2 (se non riusate il lab).
- ☑️ Un push su `main` (o `workflow_dispatch`) → i 3 job verdi → commit `ci: bump image tags ...` sul
  config-repo → Argo CD fa il rollout della nuova immagine.

> **Sincronizzazione con 2.6/2.7:** il primo merge di 2.6/2.7 su `main` sarà anche il **primo test reale**
> della pipeline end-to-end. Comodo: un colpo solo valida CI + GitOps + Argo CD.

---

## 8. Definition of Done — Fase 3

Mappa ai punti di `traccia/FASI_PROGETTO.md` (Fase 3) e a `docs/capstone-dod.md`:

| DoD item (Fase 3) | Coperto da | Spunta quando |
|---|---|---|
| Componenti di piattaforma installati (Traefik, cert-manager, CNPG ≥1.25, Strimzi, Sealed Secrets, Argo CD) | §2, §3 | tutti gli operatori `Running`, CRD presenti |
| CI collegata ai repo GitHub veri (secret ACR + PAT) | §7 | pipeline verde end-to-end, commit di bump sul config-repo |
| Argo CD **Synced & Healthy** + drift/reconcile provato | §5 | `argocd app get` Synced/Healthy + self-heal dimostrato |
| Replica sincrona CNPG + Secret `<db>-app` iniettati | §6.1, §6.2 | `cnpg status` mostra sync; env DB popolate nei pod |

**Vincoli di consegna del corso** (Lab03/04, deck 02/08): nessun `helm install`/`kubectl apply` per le
*release applicative* (solo Argo CD); segreti in Git **solo** come SealedSecret; **zero credenziali cluster
in CI**; ogni scelta non ovvia annotata in `docs/design.md` (decisioni D-A..D-G qui sopra) e in
`platform/README.md` (versioni pinnate). Se emerge un errore reale dell'agente durante il bootstrap →
annotarlo in `docs/agent-log.md`.

---

## 9. Ordine di esecuzione + lavoro in parallelo

**Catena obbligata (un solo proprietario del cluster alla volta):**
1. §1 Provisioning Azure (RG, ACR, AKS, attach-ACR, kubeconfig).
2. §2 Operatori di piattaforma (nell'ordine: cert-manager → Traefik → Sealed Secrets → CNPG → Strimzi → Argo CD).
3. §3 CR di piattaforma (Kafka + topic; ClusterIssuer TLS).
4. §5 Argo CD → app Synced & Healthy → §6 verifiche.

**Parallelizzabile da subito (non tocca il cluster):**
- §7 Config CI: chi ha accesso admin ai repo GitHub imposta secret/variabili **mentre** un altro provisiona
  il cluster. Si incontrano al primo push.
- §0bis: chiudere le decisioni D-A..D-G a voce **prima** di lanciare `az aks create` (D-C/D-E cambiano i comandi).

**Eseguibile ORA, in parallelo a 2.6/2.7:** tutta la Fase 3. Nessun file dell'app toccato → zero conflitti.

> **Regola d'oro (invariata):** nessuno modifica il cluster a mano per le release dell'app. Gli operatori si
> installano una volta (a mano, è bootstrap); da lì in poi si cambia Git e Argo CD allinea. Spegni il
> cluster (`az aks stop`) quando non lavori.

---

## Appendice A — Comandi di riferimento (adatta nomi/region/versioni dopo aver chiuso D-A..D-G)

```bash
# --- 1. Provisioning ---
RG=rg-eurotransit-g03; LOC=westeurope; AKS=eurotransit-aks; ACR=lab02g03registry
az group create -n $RG -l $LOC
# (se l'ACR del lab non esiste più: az acr create -n <nuovoacr> -g $RG --sku Basic)
az aks create -g $RG -n $AKS -l $LOC \
  --node-count 2 --node-vm-size Standard_B4ms \
  --tier free --generate-ssh-keys --attach-acr $ACR
az aks get-credentials -g $RG -n $AKS

# --- 1.3 Scalare a 3 nodi SOLO per chaos experiment (Fase 6) e demo, poi tornare a 2 ---
az aks scale -g $RG -n $AKS --node-count 3
az aks scale -g $RG -n $AKS --node-count 2

# --- 1.4 Controllo costi (spegni quando non lavori) ---
az aks stop  -g $RG -n $AKS      # dealloca i nodi: smetti di pagare il compute
az aks start -g $RG -n $AKS      # riprendi

# --- 2. Operatori (pinna le versioni!) ---
# cert-manager
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
  --create-namespace --set crds.enabled=true
# Traefik
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace
# Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
# CloudNativePG (>= 1.25)  — come da platform/cloudnativepg/README.md
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
# Strimzi
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n kafka --create-namespace
# Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# --- 3. Piattaforma: Kafka + topic ---
kubectl apply -f platform/strimzi/kafka.yaml
kubectl apply -f platform/strimzi/kafka-topics.yaml
# (+ creare il ClusterIssuer Let's Encrypt staging->prod per il TLS)

# --- 5. App via Argo CD ---
kubectl apply -f platform/argocd/eurotransit-application.yaml
# verifica:
kubectl get applications -n argocd
kubectl get pods,cluster,kafka -n eurotransit
```

## Appendice B — Mappa file toccati/letti dalla Fase 3

- **Letti, dati per buoni (non modificare):** `deploy/charts/eurotransit/**` (chart già valido),
  `platform/strimzi/*.yaml`, `platform/argocd/eurotransit-application.yaml`.
- **Da aggiornare SOLO se cambiate ACR/dominio (D-E/D-G):** `values.yaml` (`global.registry`,
  `global.domain`, `services.*.image.repository`), `platform/argocd/eurotransit-application.yaml` (`repoURL`),
  `ci.yml` (`env.REGISTRY`).
- **Da arricchire (append):** `docs/design.md` (decisioni D-A..D-G), `platform/README.md` (versioni operatori
  pinnate), `docs/agent-log.md` (se emerge un errore reale durante il bootstrap), `docs/capstone-dod.md`
  (spunte Fase 3).
- **Config esterna (non in Git):** secret/variabili CI su GitHub (§7); kubeconfig locale.
