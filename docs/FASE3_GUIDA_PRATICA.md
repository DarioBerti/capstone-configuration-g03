# Fase 3 — Guida pratica "cosa fare davvero"

> ℹ️ **INFORMAZIONI CLUSTER (già esistenti — NON ricreare):**
> - **resource group:** `lab02_g03_group`
> - **cluster AKS:** `lab_g03_cluster`
> - **region:** `spaincentral`
> - **ACR (registry):** `labg03clusterregistry` (`labg03clusterregistry.azurecr.io`, sub "Azure for Students",
>   RG `labg03clusterregistry_group`). ⚠️ D-G diceva `lab02g03registry` ma quel nome **non esiste**: il
>   registry reale è questo → `values.yaml` e `ci.yml` sono stati aggiornati di conseguenza.
> - **credito Azure residuo:** ~64€ → con il cluster acceso ~8€/giorno restano **~8 giorni h24**.
>   `az aks stop` quando non lavori non è opzionale: è ciò che fa arrivare alla demo (vedi §1.4).
>
> 
> aks-etpool-20149210-vmss000000   Ready    <none>   72m     v1.33.12   Standard_B2s_v2

> aks-etpool-20149210-vmss000001   Ready    <none>   3m4s    v1.33.12   Standard_B2s_v2

> aks-etpool-20149210-vmss000002   Ready    <none>   2m43s   v1.33.12   Standard_B2s_v2

> strimzi-cluster-operator-6bb56dd546-684rr   1/1     Running   0          113s


---

## TL;DR — la Fase 3 in una frase

Accendi un cluster AKS reale, installi 6 operatori a mano una volta sola, fai partire Kafka + il TLS,
poi **Argo CD prende il chart dal config-repo e fa girare l'app da solo**. Colleghi la CI di GitHub
(che builda le immagini e bumpa i tag), e dimostri 4 cose: operatori up, Argo **Synced & Healthy**,
self-heal del drift, replica sincrona CNPG + secret DB iniettati.

**Chi fa cosa:** una persona sola "possiede" il cluster e fa §0→§6 in sequenza (è una catena, non si
parallelizza sul cluster). **In parallelo**, un'altra persona con accesso admin ai repo GitHub fa §7
(secret CI) senza toccare il cluster. Vi incontrate al primo `git push`.

> ⚠️ **Regola d'oro che ti fa bocciare se la rompi:** per le *release dell'app* **mai** `helm install` o
> `kubectl apply` a mano. Gli operatori sì (è bootstrap, una volta). L'app **solo** via Argo CD.
> E **zero credenziali del cluster nella CI**.

---

## §0 — Prerequisiti: installa i tool e fai login (10 minuti, una volta)

Prima di toccare qualsiasi cosa, sulla **tua** macchina servono questi comandi. Verifica con `--version`:

```bash
az version          # Azure CLI
kubectl version --client
helm version
kubeseal --version  # serve solo se sigillerai un secret (probabilmente NO in Fase 3, vedi §4)
jq --version        # comodo per leggere output JSON
```

Se ne manca uno:
- **Azure CLI** → `https://learn.microsoft.com/cli/azure/install-azure-cli`
- **kubectl** → `az aks install-cli` (te lo installa l'Azure CLI)
- **helm** → `https://helm.sh/docs/intro/install/`

Poi autenticati ad Azure (apre il browser):

```bash
az login
az account show          # controlla di essere sulla subscription giusta (quella con il credito studente)
# se hai più subscription:
az account set --subscription "<NOME-O-ID-SUBSCRIPTION>"
```

> ⚠️ **Importante (D-A):** il cluster è **uno solo e condiviso** (`lab_g03_cluster`, già esistente). Nessuno
> ne crea uno nuovo: i membri vengono **aggiunti come admin** a quello esistente (vedi §1.4).
> Bruciare il credito in parallelo su più cluster è esattamente ciò che D-B/D-A vogliono evitare.

✅ **Fatto quando:** `az account show` mostra la subscription giusta e tutti i tool rispondono a `--version`.

---

## §1 — Provisioning Azure (il proprietario del cluster fa questo)

Imposta una volta queste variabili nella **stessa shell** (le riusi in tutti i comandi sotto):

```bash
RG=lab02_g03_group        # resource group ESISTENTE
LOC=spaincentral          # region del cluster esistente
AKS=lab_g03_cluster       # cluster AKS ESISTENTE
ACR=labg03clusterregistry # ACR reale del gruppo (D-G citava "lab02g03registry" che NON esiste)
```

### 1.0 — Decisione resource group: si RIUSA `lab02_g03_group` (non se ne crea uno nuovo)

> 🧭 **Perché:** un cluster AKS è **legato al resource group in cui è stato creato** — non si "sposta" in un
> RG nuovo senza **ricrearlo**, e ricrearlo butterebbe via proprio il setup che vuoi tenere (cluster
> `lab_g03_cluster` già configurato, con tutti i colleghi come collaboratori). Quindi: il cluster resta dov'è
> → **si riusa `lab02_g03_group`**. Creare un RG nuovo "pulito" non ti aiuta, perché il cluster non potrebbe
> viverci dentro. I resti dei vecchi lab nello stesso RG **non danno fastidio ad AKS**: sono risorse vicine,
> non interferiscono.

### 1.1 — Il cluster esiste già → verifica e adegua (NON ricreare)

> ⚠️ Resource group e cluster **esistono già**. **NON** lanciare `az group create` né `az aks create`.
> Qui si verifica che ci sia, lo si accende, e si controlla che sia configurato come vuole la Fase 3.

**Passo 1 — accendi il cluster e prendi il kubeconfig.** Probabilmente è spento (D-B) per non bruciare credito:

```bash
az aks start -g $RG -n $AKS               # se è già acceso, dà un errore innocuo: ignoralo
az aks get-credentials -g $RG -n $AKS     # scrive il kubeconfig locale
kubectl get nodes                          # i nodi devono diventare Ready (dopo lo start dai 3-5 min)
```

**Passo 2 — adegua il node pool entro la quota disponibile.** Leggi la size dei nodi e la quota vCPU:

```powershell
kubectl get nodes -L node.kubernetes.io/instance-type
az vm list-usage -l spaincentral -o table | Select-String "vCPU"   # guarda "Total Regional vCPUs": limit
```

> ⚠️ **NOTA DI REALTÀ (riscontrata sul cluster reale, giu 2026) — leggila tutta:**
> 1. Il pool originale `lab02g03pool` era **2× `Standard_B2ls_v2`** (2 vCPU / **4 GiB**) → troppo piccolo:
>    ~9 GiB di memory requests non ci stanno.
> 2. **`Standard_B4ms` NON è disponibile** in questa subscription/region (`spaincentral`).
> 3. ⛔ **La quota regionale è solo 6 vCPU totali** → NON puoi fare 2× `B4s_v2` (servirebbero 8 vCPU). Niente
>    richiesta di aumento quota: **si sta dentro i 6 vCPU**.
>
> ✅ **Soluzione adottata: 3× `Standard_B2s_v2`** (2 vCPU / **8 GiB** ciascuno = **6 vCPU / 24 GiB**). Sta
> esatto nella quota, copre i requests (~3.3 vCPU / ~9 GiB) con margine sulla RAM, e **3 nodi** sono pure
> meglio per le demo di resilienza (topology spread / PDB). ⚠️ NON usare `B2ls_v2`/`B2as_v2` low-memory.

**Migrazione entro i 6 vCPU (l'ordine conta: non superare mai 6).** Non puoi cancellare il vecchio pool per
primo (un cluster deve sempre avere ≥1 system pool attivo), quindi:

```powershell
# 1) nuovo System pool con UN nodo B2s_v2 (usa i 2 vCPU liberi)
az aks nodepool add -g $RG --cluster-name $AKS -n etpool `
  --node-count 1 --node-vm-size Standard_B2s_v2 --mode System
# 2) elimina il vecchio pool sottodimensionato -> libera i suoi 4 vCPU (cordon+drain automatico)
az aks nodepool delete -g $RG --cluster-name $AKS -n lab02g03pool
# 3) ora c'è spazio: scala il nuovo pool a 3 nodi
az aks nodepool scale -g $RG --cluster-name $AKS -n etpool --node-count 3
# verifica: 3 nodi Ready, tutti Standard_B2s_v2
kubectl get nodes -L node.kubernetes.io/instance-type
```

> 🟡 **Caveat per la Fase 6 (non ora):** con tutti i 6 vCPU occupati, un chaos *node-kill* lascia 4 vCPU →
> alcuni pod resteranno `Pending` invece di rischedularsi. Per quella demo scalerai temporaneamente
> `catalog` o ridurrai un request; è di per sé un *finding* da documentare. Per la Fase 3 va tutto bene.
> Se in futuro otterrai più quota, la strada "pulita" sarebbe 2× `Standard_B4s_v2` (4 vCPU/16 GiB).

**Passo 3 — assicura il pull dall'ACR (D-F, managed identity).** Potrebbe non essere ancora collegato:

```bash
az aks update -g $RG -n $AKS --attach-acr $ACR
```

> Questo comando è **idempotente**: se l'ACR è già attaccato non rompe niente. Dà al cluster il diritto di
> pullare le immagini private senza `imagePullSecret`. Verifica che l'ACR esista: `az acr show -n $ACR -o table`.

> 📌 **D-C vs realtà:** il piano teorico diceva 2× `B4s_v2`, ma la quota di 6 vCPU impone **3× `B2s_v2`**
> (6 vCPU / 24 GiB). I requests (~3.3 vCPU / ~9 GiB) ci stanno con margine sulla RAM. Annota questo
> scostamento in `docs/design.md` (D-C → "vincolo quota: 3× B2s_v2 invece di 2× B4s_v2").

✅ **Fatto quando:** `kubectl get nodes` mostra i nodi `Ready` e `az aks nodepool list` conferma il sizing.

### 1.2 — Verifica che il pull dall'ACR funzioni (test veloce)

```bash
az acr login -n $ACR
kubectl run acrtest --image=$ACR.azurecr.io/eurotransit/catalog:latest --restart=Never
kubectl get pod acrtest -w     # deve arrivare a Running, NON ImagePullBackOff
kubectl delete pod acrtest
```

✅ **Fatto quando:** il pod parte senza `ImagePullBackOff` (= la managed identity pulla davvero).
Se l'immagine `catalog:latest` non esiste ancora in ACR (la CI non è mai girata), questo test puoi
saltarlo e verificarlo dopo §7.

### 1.3 — 💰 Controllo costi: SPEGNI quando non lavori (D-B, la decisione che ti salva il credito)

Questa è **la** cosa che fa stare il progetto nel budget. Acceso h24 brucia **~8€/giorno**; spento paghi
solo i dischi (centesimi). ⚠️ **Restano ~64€**: acceso h24 sono **~8 giorni** e poi il cluster muore prima
della demo. Spento tra una sessione e l'altra, quei 64€ bastano per settimane di lavoro effettivo.

```bash
az aks stop  -g $RG -n $AKS     # FINITO di lavorare: dealloca i nodi, smetti di pagare il compute
az aks start -g $RG -n $AKS     # RIPRENDI: ~3-5 min per tornare su (i dati restano, sono su disco)
```

> ⚠️ **Abituati al riflesso:** ogni volta che chiudi la sessione → `az aks stop`. Mettilo in un alias o
> in un mini-script. Dopo `start`, dai 3-5 minuti agli operatori per ripartire prima di verificare.

✅ **Fatto quando:** dopo `az aks stop` il portale Azure mostra i nodi *Stopped* e il credito compute
smette di scendere.

Poi **ogni compagno** lancia `az aks get-credentials -g $RG -n $AKS` e ha il cluster.

✅ **Fatto quando:** un compagno riesce a fare `kubectl get nodes`.

---

## §2 — Operatori di piattaforma — ⚠️ QUASI TUTTI GIÀ INSTALLATI dai lab precedenti

> 🟢 **SCOPERTA SUL CLUSTER REALE (giu 2026):** `lab_g03_cluster` è già stato usato per i Lab 03/04/05, quindi
> **la piattaforma è già bootstrappata al 90%**. NON reinstallare ciò che c'è già (creeresti conflitti).
> **Prima controlla, poi installa solo ciò che manca.**

**Inventario attuale (verificato):**

| Operatore | Stato sul cluster | Azione |
|---|---|---|
| **cert-manager** | ✅ già installato (ns `cert-manager`, CRD presenti) | **skip** |
| **Traefik** | ✅ già installato (ns `traefik`, CRD presenti) | **skip** |
| **CloudNativePG** | ✅ già installato — **v1.29.1** (≥ 1.25 ✔, ok per replica sincrona) | **skip** |
| **Sealed Secrets** | ✅ già installato (anche **doppio**: `kube-system` + ns `sealed-secrets`) | **skip** (vedi nota) |
| **Argo CD** | ✅ già installato (ns `argocd`) — lo **riusiamo** | **skip** (vedi §5) |
| **kube-prometheus-stack** | ✅ già presente (ns `monitoring`) — è roba di Fase 4, già pronta | lascia stare |
| **Strimzi / Kafka** | ❌ **NON installato** (nessun CRD `kafka.strimzi.io`) | **→ installa (2.1)** |

**Comando d'inventario (rilancia per ri-verificare in qualsiasi momento):**
```powershell
kubectl get pods -A
kubectl get crd | Select-String "cnpg|kafka|cert-manager|sealed|traefik"
```

> 🟡 **Pulizia consigliata (resti dei lab che mangiano i tuoi 6 vCPU):**
> - **App lab05 (`my-secure-app`)**: era ancora gestita da un'Argo CD Application che la rigenerava. Già
>   rimossa con `kubectl delete application my-secure-app -n argocd` + `kubectl delete namespace lab05-app`.
> - **Doppio Sealed Secrets**: due controller (chiavi diverse). Per la Fase 3 non sigilli nulla (§4), quindi
>   non blocca; se in futuro userai `kubeseal`, tieni **un solo** controller e nota quale.
> - **kube-prometheus-stack** è pesante: se sui 3 nodi vedi pod `Pending` per mancanza di risorse, puoi
>   scalare a 0 temporaneamente Grafana/Prometheus finché non sei in Fase 4. Tienilo a mente.

### 2.1 — Strimzi (l'UNICO operatore da installare) — namespace `kafka`

```bash
helm repo add strimzi https://strimzi.io/charts && helm repo update
helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n kafka --create-namespace --version 1.0.0
kubectl get pods -n kafka
```

> ⚠️ **PINNA LA VERSIONE** (qui `1.0.0`, non `latest`) e annotala in `platform/README.md` — riproducibilità
> (igiene Lab04). Controlla l'ultima patch stabile prima di fissarla.
>
> 🔁 **Aggiornato (giu 2026):** installato l'operatore **1.0.0**. Attenzione: Strimzi 1.0.0 è *breaking* —
> ha rimosso l'API `kafka.strimzi.io/v1beta2` (usa `v1`) e Kafka 3.9.0 (usa una 4.x, qui `4.1.2`). I manifest
> in `platform/strimzi/` sono già adeguati. Se reinstalli con una versione diversa, riallinea apiVersion e
> `spec.kafka.version` di conseguenza.

### Verifica finale §2

```powershell
kubectl get pods -n kafka                                  # operatore Strimzi Running
kubectl get crd | Select-String "kafka.strimzi.io"         # CRD Kafka ora presenti
```

✅ **Fatto quando:** l'operatore Strimzi è `Running` e compaiono i CRD `kafkas.kafka.strimzi.io`,
`kafkatopics.kafka.strimzi.io`. Gli altri operatori erano già presenti (vedi tabella).

---

## §3 — CR di piattaforma: Kafka + TLS

> 🎓 **Teoria — perché qui usi i CR e non comandi imperativi.** In §2 hai installato gli *operatori*:
> programmi che girano nel cluster e sanno **come** costruire un pezzo di infrastruttura. In §3 dici loro
> **cosa** vuoi, applicando dei *Custom Resource* (CR), cioè oggetti YAML di un tipo che l'operatore ha
> aggiunto a Kubernetes (i CRD installati in §2). Tu descrivi lo *stato desiderato* (un cluster Kafka, un
> certificato TLS), l'operatore lo *riconcilia* di continuo fino a realizzarlo. È il modello dichiarativo:
> non scrivi i passi, scrivi il risultato.

### 3.1 — Kafka cluster + topic (Strimzi)

I file sono **già scritti**, applicali così come sono:

```bash
cd <path-al-config-repo>      # capstone-configuration-g03
kubectl apply -f platform/strimzi/kafka.yaml
kubectl apply -f platform/strimzi/kafka-topics.yaml
kubectl get kafka,kafkanodepool,kafkatopic -n kafka -w
```

> 🎓 **Cosa fanno i comandi.** `kubectl apply -f` manda il file YAML all'API di Kubernetes come stato
> desiderato; l'operatore Strimzi vede il nuovo CR `Kafka` e crea per te broker, storage e rete. `kafka.yaml`
> definisce il *cluster* (con `KafkaNodePool` = i gruppi di nodi/broker), `kafka-topics.yaml` definisce i
> *topic* (le code di messaggi su cui i microservizi si scambiano eventi in modo asincrono). `kubectl get ...
> -w` resta in *watch* (`-w`) e ti mostra lo stato evolvere in tempo reale invece di una sola foto.

> 🔁 Il bootstrap interno `eurotransit-kafka-bootstrap.kafka.svc:9092` combacia già con
> `values.yaml` (`global.kafkaBootstrap`) → i servizi `usesKafka` lo ricevono via env. **Nessuna modifica.**

✅ **Fatto quando:** `kubectl get kafka -n kafka` mostra il cluster `Ready=True` e ci sono **7 KafkaTopic**.
Il cluster Kafka ci mette qualche minuto a diventare Ready (deve formare il quorum KRaft a 3 nodi).

### 3.2 — TLS: il pezzo che NON è ancora in nessun file (D-E)

Qui c'è il lavoro "vero" della Fase 3 che il piano teorico dà per scontato. **Due cose mancano e le devi
creare tu:**

> 🎓 **Teoria — cos'è il TLS qui e chi sono gli attori.** Vuoi che il traffico verso l'app viaggi su HTTPS
> con un certificato *fidato dai browser*. Servono tre cose: (1) un *hostname* pubblico che punti al cluster
> (lo risolvi con `sslip.io`, un DNS che traduce `1.2.3.4.sslip.io` → `1.2.3.4` senza comprare un dominio);
> (2) **cert-manager**, l'operatore che chiede e rinnova i certificati; (3) un **ClusterIssuer**, l'oggetto
> che dice a cert-manager *da quale autorità* (qui Let's Encrypt) e *con quale metodo* (ACME HTTP-01)
> ottenere i certificati. HTTP-01 prova che possiedi l'host facendo rispondere il tuo Ingress (Traefik) a una
> challenge: per questo l'hostname deve risolvere davvero all'IP di Traefik.

**(a) Aggiornare il dominio in `values.yaml`** — ora `global.domain: g03.cpo2026.it` è un **placeholder
finto**. Usa l'IP di Traefik (§2.2) con `sslip.io` (D-E: niente DNS da comprare):

```bash
TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Il tuo host sarà: ${TRAEFIK_IP}.sslip.io"
```

> 🎓 **Cosa fa il comando.** Legge il `Service` di Traefik e con `-o jsonpath=...` estrae **solo** l'IP
> pubblico che il load balancer di Azure gli ha assegnato (invece di stampare tutto l'oggetto). Quell'IP +
> `.sslip.io` diventa l'hostname che userai ovunque.

Poi modifica **una riga** in `deploy/charts/eurotransit/values.yaml`:

```yaml
global:
  domain: <TRAEFIK_IP>.sslip.io      # es. 20.61.45.12.sslip.io  (era g03.cpo2026.it)
```

E **committa** la modifica (Argo CD legge da Git, non dal tuo disco):

```bash
git add deploy/charts/eurotransit/values.yaml
git commit -m "fase3: usa hostname sslip.io basato sull'IP di Traefik per il TLS"
git push
```

> ⚠️ **Questa è l'unica modifica al chart richiesta dalla Fase 3** (a parte ACR se non riusi il lab).
> `sslip.io` risolve `20.61.45.12.sslip.io` → `20.61.45.12` automaticamente, quindi Let's Encrypt HTTP-01
> raggiunge Traefik e il certificato viene emesso. Zero DNS da gestire.

**(b) Creare il ClusterIssuer** — l'ingress (`templates/ingress.yaml`) referenzia
`cert-manager.io/cluster-issuer: letsencrypt-prod`, **ma quel ClusterIssuer non esiste in nessun file del
repo.** Devi crearlo. Crea `platform/cert-manager/clusterissuer.yaml`:

```yaml
# Let's Encrypt — prima STAGING (rate limit alto, certificati non fidati ma per testare),
# poi PROD (certificati veri, rate limit basso: non sprecarlo)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: dario.berti100@gmail.com
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: dario.berti100@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
```

> 🎓 **Teoria — staging vs prod e il flusso ACME.** Un `ClusterIssuer` è *cluster-wide* (vale in tutti i
> namespace, a differenza di un `Issuer`). Ne definisci due perché Let's Encrypt **prod** emette certificati
> veri ma ha un *rate limit* severo: prima provi su **staging** (certificati non fidati ma limiti larghi) per
> verificare che la catena funzioni, poi passi a prod. `privateKeySecretRef` è la chiave del tuo *account*
> ACME (cert-manager la crea da sé); `solvers.http01.ingress` dice di risolvere la challenge tramite l'Ingress
> Traefik.

Applicalo a mano (è piattaforma, non app → `kubectl apply` è legittimo qui):

```bash
kubectl apply -f platform/cert-manager/clusterissuer.yaml
kubectl get clusterissuer    # entrambi devono diventare Ready=True
git add platform/cert-manager/clusterissuer.yaml && git commit -m "fase3: ClusterIssuer Let's Encrypt staging+prod" && git push
```

> 🎓 **Cosa fanno i comandi.** `kubectl apply` registra i due issuer; `Ready=True` significa che cert-manager
> ha contattato Let's Encrypt e l'account ACME è valido. Il `git add/commit/push` non serve a Kubernetes ora
> (lo hai già applicato a mano), ma mette il file **in Git**: è la fonte di verità da cui Argo CD (§5) e i
> colleghi ripartiranno — la piattaforma deve essere riproducibile, non vivere solo sul tuo disco.

> ⚠️ **Strategia anti rate-limit:** Let's Encrypt **prod** ha un limite duro (5 cert/settimana per dominio).
> Per il primo giro **testa con staging**: temporaneamente cambia in `templates/ingress.yaml` l'annotation in
> `cluster-issuer: letsencrypt-staging`, committa, fai emettere il cert (sarà "non fidato" nel browser ma
> dimostra che la catena funziona). Quando tutto gira, rimetti `letsencrypt-prod` e committa. Non sprecare
> tentativi prod su una config rotta.

✅ **Fatto quando (dopo §5, quando l'app è su):** `kubectl get certificate -n eurotransit` mostra
`eurotransit-tls` con `Ready=True`, e `curl https://<TRAEFIK_IP>.sslip.io/api/catalog/...` risponde in TLS.

---

## §4 — Secrets: (spoiler) probabilmente NON devi sigillare niente

Questo è il §4 più corto che ci sia, ed è **voluto** (è una proprietà di design, scrivilo nei docs).

> 🎓 **Teoria — il problema dei segreti in GitOps.** In GitOps *tutto* sta in Git, ma un `Secret` Kubernetes
> è codificato in base64, **non cifrato**: committarlo in chiaro è una falla. Le soluzioni: (a) un
> **SealedSecret** = un Secret *cifrato* con la chiave pubblica del controller, sicuro da mettere in Git
> perché solo il controller in-cluster può decifrarlo; (b) far **generare** il segreto direttamente
> nel cluster da chi lo possiede, così non passa mai da Git. Qui vince (b): CNPG crea le password DB,
> la managed identity gestisce il pull ACR → non resta nessun segreto da committare. `secretKeyRef` è il
> meccanismo con cui il Deployment legge un valore da un Secret e lo inietta come variabile d'ambiente.

- **Credenziali DB:** **zero segreti in Git.** L'operatore CNPG genera da solo il Secret `<db>-app`
  in-cluster (es. `orders-db-app`); il Deployment lo legge via `secretKeyRef`. Già cablato nel chart.
- **Pull immagini:** gestito dalla managed identity (§1.1 `--attach-acr`) → **niente `imagePullSecret`**.
- **Quando servirebbe un SealedSecret:** solo se introdurrai un segreto applicativo vero (es. un token PSP
  reale — ora il PSP è mock). In quel caso: `platform/sealed-secrets/README.md` → `kubeseal` → committi
  **solo** il SealedSecret.

> 📝 **Azione concreta:** scrivi una riga in `docs/design.md`: *"Fase 3: nessun SealedSecret necessario —
> credenziali DB generate da CNPG in-cluster, pull ACR via managed identity. È design, non dimenticanza."*

✅ **Fatto quando:** confermato che non c'è nessun `Secret` in chiaro in Git e i pod app partiranno con le
`DB_*` iniettate (lo verifichi in §6.2).

---

## §5 — Il cuore della Fase 3: Argo CD → app **Synced & Healthy**

> 🎓 **Teoria — cos'è GitOps e cosa fa Argo CD.** GitOps significa: lo stato desiderato del cluster vive in
> un repo Git, e un agente lo applica al posto tuo. **Argo CD** è quell'agente. Gli dai un oggetto
> `Application` che dice "guarda *questo* repo/path (il chart Helm `eurotransit`) e fai sì che il cluster gli
> assomigli". Argo confronta di continuo *desiderato* (Git) vs *reale* (cluster) e riporta due stati:
> **Synced** (il cluster coincide con Git) e **Healthy** (le risorse girano davvero). Con `selfHeal` annulla
> le modifiche fatte a mano (drift) e con `prune` cancella ciò che togli da Git. Per questo la regola d'oro è
> "mai `helm install` a mano sull'app": Git è l'**unica** fonte di verità.

### 5.1 — Accedi alla UI di Argo CD (utile per vedere lo stato)

```bash
# password admin iniziale:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# apri la UI in locale:
kubectl port-forward -n argocd svc/argocd-server 8080:443
# → vai su https://localhost:8080  (user: admin, password: quella sopra)
```

> 🎓 **Cosa fanno i comandi.** Il primo legge il Secret con la password generata da Argo all'installazione e
> la decodifica (`base64 -d`, perché i Secret sono salvati in base64). `kubectl port-forward` apre un tunnel
> dalla tua porta locale `8080` alla porta `443` del Service di Argo dentro il cluster: ti fa raggiungere la
> UI **senza** esporla pubblicamente.

(Opzionale: installa la CLI `argocd` per i comandi `argocd app get`.)

### 5.2 — Se il config-repo è PRIVATO, registra le credenziali in Argo CD

Il repo è `https://github.com/DarioBerti/capstone-configuration-g03.git`. Se è **privato**, Argo CD non può
clonarlo finché non gli dai le credenziali. Modo rapido (per il bootstrap; in produzione si userebbe un
SealedSecret come dice `platform/README.md`):

```bash
argocd login localhost:8080 --username admin --password '<password-di-sopra>' --insecure
argocd repo add https://github.com/DarioBerti/capstone-configuration-g03.git \
  --username <tuo-user-github> --password <PAT-con-read-sul-config-repo>
```

> Se il repo è **pubblico**, salta questo step.

### 5.3 — Crea l'Application (il file è già pronto)

```bash
kubectl apply -f platform/argocd/eurotransit-application.yaml
kubectl get applications -n argocd
```

> 🎓 **Cosa fa il comando.** Crei l'oggetto `Application`: da questo momento Argo CD "adotta" il chart e
> inizia a sincronizzarlo. `kubectl get applications` ti mostra la riga `eurotransit` con le colonne
> `SYNC STATUS` e `HEALTH STATUS` — gli stessi due indicatori della UI, da terminale.

> 🔁 Verifica che `repoURL` nel file sia l'URL **giusto** del vostro config-repo. Ho controllato il git
> remote: è `https://github.com/DarioBerti/capstone-configuration-g03.git` → **combacia, non modificare**.

### 5.4 — Primo sync (automatico)

Con `automated: {prune, selfHeal}` già impostati, Argo CD sincronizza **da solo**. Guarda nella UI o:

```bash
kubectl get pods -n eurotransit -w
```

> 📘 **Ordine interno (lo gestisce Argo):** prima i `Cluster` CNPG → l'operatore crea i Postgres e i Secret
> `<db>-app` → poi i Deployment partono e leggono quei Secret. **Se per un attimo vedi i pod app in
> `CreateContainerConfigError`** è perché il Secret CNPG non è ancora pronto: **si risolve da solo** al
> reconcile successivo. È atteso, non è un bug — non panic-fixare a mano.

✅ **Fatto quando:** `argocd app get eurotransit` (o la UI) mostra **Synced** e **Healthy**, e
`kubectl get pods -n eurotransit` ha tutti i pod `Running`/`Ready`.

### 5.5 — Prova drift + reconcile (la traccia lo CHIEDE esplicitamente)

Devi **dimostrare** che Git è l'unica verità. Fai una modifica "fuori banda" e guarda Argo annullarla:

> 🎓 **Teoria — drift e reconcile.** *Drift* = divergenza tra lo stato reale e quello descritto in Git
> (qualcuno ha toccato il cluster a mano). *Reconcile* = il ciclo con cui Argo rileva la divergenza e
> riallinea. Qui la provochi apposta per dimostrare che `selfHeal` annulla le modifiche manuali e `prune`
> ricrea ciò che cancelli: è la prova che il sistema è auto-correttivo.

```bash
# 1) drift: scala a mano un deployment
kubectl scale deploy/catalog -n eurotransit --replicas=5
kubectl get deploy/catalog -n eurotransit -w
#    -> selfHeal lo riporta a 2 da solo entro pochi secondi. SCREENSHOTTA questo.

# 2) prune: cancella una risorsa a mano
kubectl delete deploy/catalog -n eurotransit
#    -> Argo la ricrea. SCREENSHOTTA.
```

> 🎓 **Cosa fanno i comandi.** `kubectl scale` cambia a mano il numero di repliche (5 invece delle 2 in Git):
> stai *mentendo* al cluster di proposito. `kubectl delete` rimuove del tutto il Deployment. In entrambi i
> casi Argo, vedendo che il reale non coincide più con Git, ripristina lo stato corretto da solo — ed è
> esattamente ciò che la traccia vuole vedere catturato.

> 📸 **Salva screenshot/log del self-heal** — servono per la demo (Fase 6) e per la riga nei docs.
> Questo è letteralmente un punto della Definition of Done.

✅ **Fatto quando:** hai visto (e catturato) Argo CD ripristinare sia lo scale-out manuale sia la risorsa
cancellata.

---

## §6 — Le 4 verifiche che la traccia vuole PROVATE (non dichiarate)

> 🎓 **Teoria — perché proprio queste 4 prove.** La traccia distingue tra *dichiarare* una proprietà e
> *dimostrarla* con un comando ripetibile. Le quattro toccano i punti critici: **replica sincrona CNPG** →
> garantisce **RPO=0** (Recovery Point Objective: zero dati persi, perché una scrittura è confermata solo
> quando è anche sulla replica) sull'invariante "niente oversell" di inventory; **Secret iniettati** →
> conferma che i pod girano col profilo Postgres vero e non con un DB H2 di fallback; **health del
> money-path** → prova che la catena di eventi attraversa davvero i servizi fino allo stato CONFIRMED.

```bash
# 6.1 — Replica sincrona CNPG (RPO=0 sull'invariante inventory)
kubectl get cluster -n eurotransit
#   -> inventory-db: 3 istanze, orders-db: 2 istanze
kubectl cnpg status inventory-db -n eurotransit    # serve il plugin kubectl-cnpg
#   -> deve mostrare la replica SINCRONA attiva
```
> Se non hai il plugin: `kubectl krew install cnpg` oppure
> `curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh`.
> In alternativa leggi lo status grezzo: `kubectl get cluster inventory-db -n eurotransit -o yaml | grep -A5 synchronous`.

> 🎓 **Cosa fanno i comandi (6.1).** `kubectl get cluster` elenca i `Cluster` CNPG e quante istanze ha
> ciascuno (inventory-db a 3, orders-db a 2). `kubectl cnpg status` è un sotto-comando del plugin CNPG che
> mostra ruolo dei pod (primario/replica) e se la replica è **sincrona** (il primario aspetta la conferma
> della replica prima di confermare il commit = nessuna perdita su failover).

```bash
# 6.2 — Secret <db>-app iniettati nei pod (profilo postgres, non H2)
kubectl exec -n eurotransit deploy/orders -- printenv | grep -E 'DB_HOST|DB_NAME|DB_USER'
#   -> devono essere popolate dai Secret CNPG (orders-db-app)
```

> 🎓 **Cosa fa il comando (6.2).** `kubectl exec ... -- printenv` esegue `printenv` **dentro** il container
> del pod orders e ne stampa le variabili d'ambiente; `grep` filtra quelle del DB. Se sono valorizzate,
> significa che il `secretKeyRef` ha pescato davvero i valori dal Secret `orders-db-app` generato da CNPG.

```bash
# 6.3 — Health del money-path end-to-end (via Traefik)
curl -k https://<TRAEFIK_IP>.sslip.io/api/catalog/products      # legge il catalogo in TLS
# un POST /api/orders reale attraversa Orders -> outbox -> Kafka -> Inventory/Payments -> CONFIRMED
```

> 🎓 **Cosa fa il comando (6.3).** `curl` fa una richiesta HTTP dall'esterno attraverso Traefik (l'Ingress),
> esercitando tutta la catena: TLS → routing → servizio. Il flag `-k` accetta certificati non fidati: utile
> mentre sei su Let's Encrypt **staging** (§3.2); con il cert prod puoi toglierlo. Il `POST /api/orders`
> mostra il *money-path* asincrono: orders scrive nell'outbox, l'evento passa per Kafka, inventory e payments
> reagiscono, l'ordine arriva a CONFIRMED.
> Se 2.6/2.7 non sono ancora mergiati il path **funziona comunque**: mancano solo metriche/anti-storm extra.

**6.4** — Con il cluster su, il team Fase 2 può validare *live* probe/PDB/HPA/topology/graceful-degradation
(Notifications giù → checkout OK). La Fase 3 si limita a **rendere possibile** quella prova.

> 🟡 **Gotcha noto (NON bloccante):** i Deployment puntano l'OTLP tracing a
> `otel-collector.observability.svc:4318`, che **non esiste fino alla Fase 4**. L'export trace fallisce in
> silenzio (fire-and-forget) → **non** fa crashare l'app. **Consiglio: ignoralo** fino alla Fase 4, è un
> warning innocuo. Non over-engineerare un collector no-op adesso.

✅ **Fatto quando:** 6.1 mostra la replica sincrona, 6.2 mostra le env DB popolate, 6.3 risponde in TLS.

---

## §7 — Collegare la CI (in PARALLELO — chi ha accesso admin ai repo GitHub)

Questo **non tocca il cluster**: si fa mentre un altro provisiona AKS. Chiude l'anello GitOps:
`git push` sull'app-repo → immagini in ACR → bump tag nel config-repo → Argo CD riconcilia.

> 🎓 **Teoria — come si chiude l'anello e perché la CI è "cieca" sul cluster.** L'idea GitOps è separare
> *chi costruisce* da *chi rilascia*. La **CI** (GitHub Actions) builda l'immagine, la pubblica nell'ACR e
> poi *modifica il tag dell'immagine* nel config-repo (un commit). Da lì in poi **non fa nient'altro**: è
> **Argo CD**, dentro il cluster, a notare il nuovo tag in Git e a fare il rollout. Vantaggio di sicurezza:
> la CI non possiede mai le credenziali del cluster (*least privilege*) — il suo unico potere è un PAT che
> scrive **solo** sul config-repo. Se la CI venisse compromessa, non potrebbe toccare la produzione
> direttamente. Questo è un vincolo che la valutazione controlla esplicitamente.

La CI (`capstone-application-g03/.github/workflows/ci.yml`) è **già scritta**, mai eseguita. Serve solo
configurare 4 cose nelle **Settings del repo `capstone-application-g03`**:

`Settings → Secrets and variables → Actions`

| Nome | Tab | Valore | Come ottenerlo |
|---|---|---|---|
| `ACR_USERNAME` | **Secret** | admin user dell'ACR | `az acr credential show -n labg03clusterregistry --query username -o tsv` |
| `ACR_PASSWORD` | **Secret** | password ACR | `az acr credential show -n labg03clusterregistry --query 'passwords[0].value' -o tsv` |
| `CONFIG_REPO_PAT` | **Secret** | PAT con write **SOLO** sul config-repo | GitHub → Settings → Developer settings → **Fine-grained PAT** → repository = `capstone-configuration-g03`, permesso `Contents: Read and write` |
| `GITOPS_REPO` | **Variable** | `DarioBerti/capstone-configuration-g03` | è il valore letterale (owner/repo) |

> ⚠️ Per ottenere le credenziali ACR potrebbe servire abilitare l'admin user una volta:
> `az acr update -n labg03clusterregistry --admin-enabled true` (qui è già **ADMIN ENABLED: True**).

> 📘 **Vincolo di valutazione (lo controllano):** la CI **non ha mai credenziali del cluster**. Il suo unico
> potere è il `CONFIG_REPO_PAT` sul config-repo (least privilege). Verifica che nel workflow non finisca
> nessun secret del cluster.

### Test della pipeline

```bash
# dall'app-repo: un push su main (o "Run workflow" da Actions = workflow_dispatch)
git -C capstone-application-g03 commit --allow-empty -m "ci: test pipeline fase3" && git push
```

> 🎓 **Cosa fa il comando.** `git -C <dir>` esegue git in quella cartella senza doverci entrare. `commit
> --allow-empty` crea un commit *senza modifiche* di codice: serve solo a generare un evento `push` che
> *innesca* la pipeline, così la testi end-to-end senza cambiare nulla nell'app. In alternativa, "Run
> workflow" dalla tab Actions usa il trigger `workflow_dispatch` (avvio manuale) per lo stesso scopo.

✅ **Fatto quando:** i 3 job (detect → build → update-gitops) sono **verdi**, compare un commit
`ci: bump image tags ...` sul **config-repo**, e Argo CD fa il rollout della nuova immagine.

> 🔗 **Sincronizzazione con 2.6/2.7:** il **primo merge** di 2.6/2.7 su `main` sarà anche il primo test
> reale end-to-end della pipeline. Un colpo solo valida CI + GitOps + Argo CD.

---

## §8 — Definition of Done della Fase 3 (la tua checklist finale)

Spunta queste 4 + i vincoli. Sono i punti che fanno il voto.

- [ ] **Operatori installati** (Traefik, cert-manager, CNPG **≥1.25**, Strimzi, Sealed Secrets, Argo CD) →
      tutti `Running`, CRD presenti. *(§2)*
- [ ] **CI collegata ai repo veri** (secret ACR + PAT) → pipeline verde end-to-end, commit di bump sul
      config-repo. *(§7)*
- [ ] **Argo CD Synced & Healthy + drift/reconcile dimostrato** → `argocd app get` verde + screenshot del
      self-heal. *(§5)*
- [ ] **Replica sincrona CNPG + Secret `<db>-app` iniettati** → `cnpg status` mostra sync, env DB popolate
      nei pod. *(§6.1, §6.2)*

**Vincoli del corso (Lab03/04):**
- [ ] Nessun `helm install` / `kubectl apply` per le **release dell'app** (solo Argo CD). Operatori a mano = OK.
- [ ] Segreti in Git **solo** come SealedSecret (in Fase 3 probabilmente nessuno — vedi §4).
- [ ] **Zero credenziali cluster nella CI.**
- [ ] Decisioni D-A..D-G annotate in `docs/design.md` (una riga ciascuna) e versioni operatori pinnate in
      `platform/README.md`.
- [ ] Se durante il bootstrap un agente/tool sbaglia davvero → annotalo in `docs/agent-log.md` (è graded).

---

## §9 — Ordine di esecuzione (riassunto a colpo d'occhio)

**Catena sul cluster (un proprietario alla volta):**
```
§0 prerequisiti+login → §1 accendi/verifica cluster esistente + attach-ACR + kubeconfig → §2 operatori (cert-manager→Traefik→
SealedSecrets→CNPG→Strimzi→ArgoCD) → §3 Kafka+TLS(domain+ClusterIssuer) →
§5 Argo CD Synced&Healthy + drift → §6 verifiche
```
**In parallelo (non tocca il cluster):** §7 secret CI su GitHub.

**Le 2 sole cose che il piano teorico NON ti dava già pronte e che devi creare/modificare tu:**
1. **`global.domain` in `values.yaml`** → metti `<IP-Traefik>.sslip.io` (era il placeholder `g03.cpo2026.it`).
2. **`platform/cert-manager/clusterissuer.yaml`** → non esiste, l'ingress lo referenzia ma nessuno lo crea.

Tutto il resto (chart, Kafka, KafkaTopic, Application Argo CD, CI) è **già scritto**: lo applichi, non lo riscrivi.

> 💰 **E ricordati:** `az aks stop` ogni volta che smetti di lavorare. È la differenza tra finire il
> progetto e finire il credito.
