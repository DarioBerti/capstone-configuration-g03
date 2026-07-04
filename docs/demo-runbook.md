# EuroTransit — Runbook demo/orale (accensione → dimostrazioni → spegnimento)

> Sequenza COMPLETA e a prova di panico: ogni comando è commentato, le variabili si impostano UNA volta
> all'inizio (§1) e valgono per tutto. Terminale: Git Bash. Ogni port-forward vive nel SUO terminale
> (lascialo aperto); tutto il resto si fa da un terminale "di lavoro" dove hai incollato il §1.
> In fondo: "SE QUALCOSA NON VA" — leggi quello PRIMA di agitarti.

---

## 0. Prerequisiti (una tantum, non il giorno dell'orale)
- `az` loggato sull'account che possiede il cluster; `kubectl`, `helm`, `git`, `curl` nel PATH.
- Repo config aggiornato: `git checkout main && git pull` (da qui in poi si lavora DENTRO il repo).
- Contesto k8s: `az aks get-credentials -g lab02_g03_group -n lab_g03_cluster` (se mai fatto prima).

## 1. Variabili di sessione — INCOLLA TUTTO QUESTO BLOCCO per primo (nel terminale di lavoro)

```bash
# ── dove sta il cluster ──────────────────────────────────────────────────────
RG=lab02_g03_group                       # resource group Azure
CLUSTER=lab_g03_cluster                  # nome del cluster AKS

# ── gli ingressi pubblici del sistema ────────────────────────────────────────
APP=https://158.158.71.17.sslip.io       # l'app (Traefik + TLS Let's Encrypt)
KC=https://auth.g03.cpo2026.it           # Keycloak (login/token)

# ── utente demo (esiste già nel realm) ───────────────────────────────────────
DEMO_USER=smoketest
DEMO_PW=smoketest-pw-2026
TRIP=FR9592-20260629                     # tripCode di esempio (se SOLD_OUT va bene lo stesso: è un esito corretto)
```

## 2. Accensione

```bash
# accende il cluster (~4 minuti). "Stopped -> Starting -> Running"
az aks start -g $RG -n $CLUSTER

# aspetta che i 3 nodi siano Ready
kubectl config use-context lab_g03_cluster
kubectl get nodes                        # atteso: 3x Ready

# NORMALE dopo uno start: 1-2 pod "Error" con AGE alto e 0 restart = cadaveri della sessione precedente
# (uccisi dallo stop; il rimpiazzo Running esiste già). Ripuliscili, NON sono un guasto:
kubectl delete pods -A --field-selector=status.phase==Failed

# lascia 3-5 minuti ad Argo CD per riconciliare tutto, poi controlla il quadro:
kubectl -n argocd get application
#  atteso: argo-rollouts  Synced   Healthy
#          debezium       Synced   Healthy
#          eurotransit    Synced (o OutOfSync) + Healthy   <- l'OutOfSync è COSMETICO: sono i campi
#                                                             runtime che Argo Rollouts gestisce (pesi/selector)
```

> ⚠️ Se le immagini in Git sono cambiate dall'ultima sessione, **orders parte DA SOLO con un ramp canary
> di ~10 min** (è la Fase 5 che lavora, NON un guasto): `kubectl -n eurotransit get rollout orders -w`
> e aspetta `Healthy`.
>
> ⚠️ **Turbolenza normale di cold-start (verificato 04/07, ~10-15 min prima che tutto sia verde):**
> - **App in CrashLoopBackOff all'avvio** = partono prima che il loro DB CNPG accetti connessioni
>   (`orders-db-rw:5432 refused` nei log). Si auto-riprendono ai retry; per accelerare:
>   `kubectl -n eurotransit delete pod -l app.kubernetes.io/name=orders --field-selector=status.phase!=Running`.
>   Aspetta prima che i DB abbiano il primary pronto: `kubectl -n eurotransit get cluster` (il `-rw` risponde).
> - **`inventory-db` resta 2/3** ("Waiting for the instances to become active"): la 3ª istanza fatica a
>   fare join sul pool stretto (è il tema della decisione Part-2). **A 2/3 inventory FUNZIONA** (primary + 1
>   sync standby → RPO=0 con `ANY 1`); `eurotransit` resta quindi `Progressing` (non `Healthy`) ma opera.
> - Se orders finisce con troppi pod (HPA che spike a 4 + il canary): converge da solo quando l'HPA
>   scala giù da idle; se resta bloccato `Degraded`, `kubectl argo rollouts promote orders --full`.

```bash
# salute finale: nessun pod rotto da nessuna parte
kubectl get pods -A | grep -vE "Running|Completed"      # atteso: SOLO l'header (nessuna riga)
# il CDC è vivo: 3 connector RUNNING
kubectl -n kafka get kafkaconnector                      # atteso: READY=True x3
# orders gira l'immagine giusta (775b8af o più recente — quella con bucket + warm-before-ready):
kubectl -n eurotransit get rollout orders -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# i bucket dell'istogramma sono vivi (query su Prometheus :9090, appena è su — deve tornare > 0):
#   count(http_server_requests_seconds_bucket)
```

## 3. Password-grant ON + token (serve per generare traffico)

Il client `eurotransit-frontend` in prod ha il password-grant SPENTO (posture di sicurezza). Per la
demo lo accendiamo e A FINE SESSIONE lo rispegniamo. **Via UI è la strada senza panico:**

1. apri **$KC** nel browser → Administration Console → login `admin` + password da:
   ```bash
   kubectl -n eurotransit get secret keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d; echo
   ```
2. in alto a sinistra scegli il realm **eurotransit** → menu **Clients** → `eurotransit-frontend`
   → tab Settings → sezione *Capability config* → attiva **Direct access grants** → Save.
   *(A fine sessione: stessa strada, disattiva.)*

Poi, nel terminale di lavoro:
```bash
# funzione comoda: TOKEN utente demo (SCADE dopo 5 min — se un curl torna 401, rilancia questa riga)
mktoken() { TOK=$(curl -sk "$KC/realms/eurotransit/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=eurotransit-frontend&username=$DEMO_USER&password=$DEMO_PW" \
  | grep -o '"access_token":"[^"]*' | cut -d'"' -f4); echo "token ok (${#TOK} char)"; }
mktoken
```

## 4. Traffico di fondo (TERMINALE DEDICATO — incolla prima il §1)

Le dashboard/SLO/tracce hanno senso solo sotto traffico. Lascia girare questo per tutta la demo:
```bash
# un ordine ogni 5s, token rinnovato ogni giro di 30 (non scade mai a metà)
while true; do
  TOK=$(curl -sk "$KC/realms/eurotransit/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=eurotransit-frontend&username=$DEMO_USER&password=$DEMO_PW" \
    | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
  for i in $(seq 1 30); do
    curl -sk -o /dev/null -w "%{http_code} " -X POST "$APP/api/orders" \
      -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
      -d "{\"tripCode\":\"$TRIP\",\"qty\":1}"
    sleep 5
  done; echo " [token rinnovato]"
done
# atteso a video: una fila di "202 202 202..." (l'ack durevole dell'intake async)
```

## 5. Aprire i tool (OGNI riga in un SUO terminale, lasciali aperti)

```bash
# GRAFANA ─ http://localhost:3000 ─ user: admin, password:
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# PROMETHEUS ─ http://localhost:9090 (niente login)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# ARGO ROLLOUTS dashboard ─ http://localhost:3100 (scegli namespace "eurotransit" in alto)
kubectl -n argo-rollouts port-forward service/argo-rollouts-dashboard 3100:3100

# ARGO CD ─ http://localhost:8081 ─ user: admin, password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# usa la porta 80 (http): il server è in modalità insecure dietro Traefik -> il forward su :443 dà 000
kubectl -n argocd port-forward svc/argocd-server 8081:80
```
> Tempo (tracce) NON ha una sua UI: si usa da **Grafana → Explore → datasource "Tempo"**.

## 6. DEMO OBSERVABILITY (Fase 4) — cosa mostrare e cosa ti aspetti

**Stai dimostrando: "misuriamo i SINTOMI utente, e ogni segnale del money path async è visibile".**

### 6a. Prometheus (localhost:9090)
- `Status → Targets`: tutto **UP** — i 6 servizi (+`orders-canary`), `kafka-exporter`, `debezium-connect`, i DB CNPG.
- `Status → Rules`: i 4 gruppi nostri → `eurotransit-checkout-slo`, `eurotransit-saga-slo`, `eurotransit-cdc`, `eurotransit-dlt`.
- `Alerts`: nessun alert eurotransit acceso (il `Watchdog` acceso è normale — è il "sono vivo" di Prometheus).
- Query da incollare (una alla volta, tab *Graph*):
  ```promql
  debezium_metrics_connected                 # = 1 per orders/inventory/payments -> il CDC legge i WAL
  sum by (topic)(kafka_consumergroup_lag)    # ~0 -> nessun arretrato: la saga consuma in tempo reale
  eurotransit_dlt:depth:sum                  # 0 (o vuoto) -> nessun ordine morto nei DLT
  checkout_saga:terminal_ratio:rate30m       # ~1.0 -> gli ordini ACCETTATI arrivano a un esito (il 202 non basta!)
  orders_overdue_nonterminal                 # 0 -> nessun ordine bloccato oltre deadline
  ```

### 6b. Grafana (localhost:3000)
- **Dashboards** → cartella EuroTransit: apri **RED** (traffico/errori/latenza per servizio + riga saga),
  **Kafka** (lag consumer), **CNPG** (repliche/slot), **Runtime**.
- **Il pezzo forte — metrica→traccia (exemplar)**: Explore → datasource *Prometheus* → incolla:
  ```promql
  histogram_quantile(0.99, sum by (le)(rate(http_server_requests_seconds_bucket{service="orders",uri="/api/orders"}[2m])))
  ```
  attiva l'interruttore **Exemplars** → compaiono pallini sul grafico → click su un pallino →
  **"View trace in Tempo"** → si apre LA traccia esatta di quella richiesta.
- **Tracce cross-Kafka**: Explore → datasource *Tempo* → Search `service.name = orders` → apri una traccia:
  dentro ci sono span di **orders + inventory (+ notifications)** = il contesto W3C ha attraversato
  **due hop Kafka via Debezium** (colonna `traceparent` nell'outbox → header Kafka).
  *(Teniamo il 10% delle tracce sane: se una manca è il tail-sampling che lavora, non un bug.)*

### 6c. Money path a mano (la prova regina, 30 secondi)
```bash
mktoken   # (se è passato tempo)
# piazza un ordine e cattura l'orderId
curl -sk -X POST "$APP/api/orders" -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d "{\"tripCode\":\"$TRIP\",\"qty\":1}"
# -> copia "orderId" dalla risposta (status PENDING), poi interroga finché è terminale:
curl -sk "$APP/api/orders/<ORDER_ID>" -H "Authorization: Bearer $TOK"
# atteso in pochi secondi: "status":"CONFIRMED"  (oppure REJECTED/SOLD_OUT se il trip è esaurito
# — fallo notare: è il never-oversell che rifiuta pulito, NON un errore)
```

## 7. DEMO CANARY (Fase 5) — release SLO-gated davanti ai loro occhi

**Stai dimostrando: "ogni release passa da un canary automatico; se degrada, torna indietro DA SOLA".**

Trigger GitOps-onesto = un commit che cambia il tag di orders (il tag vecchio è ancora in ACR, quindi
il "rilascio" è istantaneo da pullare). Nel terminale di lavoro, DENTRO il config repo:
```bash
# 1) apri deploy/charts/eurotransit/values.yaml e cambia SOLO il tag di ORDERS
#    (services: -> orders: -> image: -> tag:) mettendo il tag precedente (chiedi a Mattia qual è,
#    oppure: git log --oneline -5 -- deploy/charts/eurotransit/values.yaml  e guarda i bump della CI)
# 2) committa e pusha: da qui in poi fa tutto il controller
git add deploy/charts/eurotransit/values.yaml
git commit -m "demo: canary release di orders"
git push

# 3) GUARDA (terminale + dashboard Rollouts su :3100):
kubectl -n eurotransit get rollout orders -w
#   atteso: Progressing -> steps 5% -> 25% -> 50% -> 100% -> Healthy (~10 min, pause comprese)
# i pesi si muovono DAVVERO sull'ingress:
kubectl -n eurotransit get traefikservice orders-weighted -o jsonpath='{.spec.weighted.services}'; echo
# l'analysis che fa da giudice (3 gate: success-rate, p99, failure consumer):
kubectl -n eurotransit get analysisrun
```
Racconto per il prof: *pesi mai scritti in Git (li muove il controller: `ignoreDifferences`),
gate = le NOSTRE query SLO di Fase 4, abort automatico = chaos 07.* Dal 03/07 il **gate p99 misura
latenza vera** (bucket abilitati in tutti i servizi) e il **warm-before-ready** dell'app evita i falsi
abort da cold-start quando i pod canary si accendono.

## 7-bis. DEMO BLUE/GREEN (Fase 5 — la seconda strategia che la traccia chiede)

**Stai dimostrando: "oltre al canary graduale, sappiamo fare il cutover atomico con smoke-test pre-flip".**
(~15 min. Il meccanismo è Rollouts nativo: la Service `orders` viene ri-puntata ATOMICAMENTE al nuovo
ReplicaSet alla promozione; prima del flip il candidato è raggiungibile in-cluster su `orders-preview`.)

```bash
# 1) passa orders alla strategia blue/green (commit in values.yaml):
#    services: -> orders: -> rollout: -> strategy: bluegreen     (era "canary")
git add deploy/charts/eurotransit/values.yaml && git commit -m "demo: switch orders to blue/green" && git push
#    Argo applica: sparisce l'IngressRoute canary (la rotta torna alla Ingress standard -> Service orders),
#    compare la Service orders-preview. Aspetta eurotransit Synced.

# 2) innesca una release (bump del tag di orders, come al §7) -> il PREVIEW sale a piena capacità
kubectl -n eurotransit get rollout orders -w        # atteso: Paused (autoPromotionEnabled=false = gate umano)

# 3) SMOKE-TEST sul preview PRIMA del flip (in-cluster, il pubblico non lo vede):
kubectl -n eurotransit run smoke --rm -i --restart=Never --image=curlimages/curl --   curl -s http://orders-preview:8080/actuator/health/readiness    # atteso: {"status":"UP"}

# 4) PROMOZIONE = flip atomico del selector (un solo comando, zero downtime):
kubectl argo rollouts promote orders -n eurotransit    # (o il bottone Promote sulla dashboard :3100)
kubectl -n eurotransit get rollout orders -w           # -> Healthy; la Service orders punta al nuovo RS

# 5) (rollback = `kubectl argo rollouts undo orders`: il vecchio RS è ancora lì, flip inverso istantaneo)

# 6) FINITA LA DEMO: torna alla strategia canary (commit inverso di strategy) e riallinea il tag se serve.
```
> ⚠️ Racconta anche il caveat async (design §4-D): il preview a piena capacità **consuma già le reply Kafka**
> prima del flip — il cutover atomico governa l'HTTP; la garanzia sul lato eventi è la compatibilità tra
> versioni adiacenti. Detto al prof, è un punto di comprensione profonda, non una debolezza.

## 8. DEMO CHAOS (Fase 6) — i due da orale (veloci e leggibili)

> La suite completa (8 esperimenti, ordine 08→02→01→06→04→05→03→07) sta in `docs/chaos/README.md`,
> un runbook per esperimento con criteri PASS. Per l'orale i due più efficaci:

### 8a. Poison message → DLT (chaos 08 — 1 comando, niente Chaos Mesh)
**Dimostra: un messaggio avvelenato NON blocca il money path — retry limitato, poi quarantena.**
```bash
# butta un payload NON-JSON sul topic dei comandi di inventory:
kubectl -n kafka run kafka-poison --rm -i --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.1.2 -- \
  bin/kafka-console-producer.sh \
    --bootstrap-server eurotransit-kafka-bootstrap.kafka.svc:9092 \
    --topic reserve-seats <<< 'this-is-not-json'

# osserva: 3 retry da 500ms nei log di inventory, poi il messaggio finisce in inventory-dlt:
kubectl -n eurotransit logs deploy/inventory --tail=30 | grep -iE "error|dead"
# su Prometheus: eurotransit_dlt:depth:sum passa a 1 (e l'alert DeadLetterTopicNotEmpty arma dopo 5m)
# e INTANTO il loop di traffico continua a fare 202 -> CONFIRMED: la partizione NON è bloccata.
```
*(runbook completo con la lettura del DLT e i PASS: `docs/chaos/08-poison-message-dlt.md`)*

### 8b. Canary auto-abort (chaos 07 — il gran finale, richiede un rollout in corso)
**Dimostra: una release guasta viene ABORTITA dal sistema, zero umani nel loop.**
1. innesca un rollout come al §7 e, mentre il ramp è al 5-25%:
2. prendi l'hash del canary e applica il degrado (2s di latenza SOLO sui pod canary→DB):
   ```bash
   HASH=$(kubectl -n eurotransit get rs -l app.kubernetes.io/name=orders \
     -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash} {.spec.replicas}{"\n"}{end}' \
     | awk '$2>0' | tail -1 | cut -d' ' -f1)
   sed "s/REPLACE_WITH_CANARY_HASH/$HASH/" platform/chaos-mesh/07-canary-auto-abort.yaml | kubectl apply -f -
   ```
3. guarda su :3100 / terminale: il gate `canary-intake-ack-p99` fallisce 3 volte (~90s) →
   **Degraded / RolloutAborted** → pesi istantaneamente a 100/0 sullo stable. Lo stable NON ha mai sofferto.
4. pulizia: `kubectl -n eurotransit delete networkchaos canary-db-latency`
   *(runbook e criteri PASS: `docs/chaos/07-canary-auto-abort.md`)*

> **Chaos Mesh è GIÀ installato su AKS** (2.8.3, fatto il 03/07 durante il dry-run) → salta l'install.
> ⚠️ Se mai lo reinstalli **da Git Bash su Windows**: il path del socket viene mangiato
> (`/run/containerd/...` → `C:/Program Files/Git/run/containerd`) e i `chaos-daemon` vanno in CrashLoop →
> prefissa il comando con `MSYS_NO_PATHCONV=1 helm ...`. (agent-log #25)

> **NOTA sul 07 (aggiornata 03/07 sera):** l'**abort automatico è provato**; con i bucket abilitati il gate
> p99 ora **misura latenza reale** (prima era no-op via `vector(0)`). Restano le due regole d'oro: inietta
> quando il canary è a **≥25%** di peso (a 5% ci sono troppi pochi campioni per muovere un p99) e latenza
> **~1.2s** (già nel manifest — ~2s fa scattare prima la *readiness DB* → abort via ProgressDeadlineExceeded,
> comunque safe ma non è il gate che vuoi mostrare). PASS che conta sempre: *stable mai promosso, mai sofferto*.

## 9. Spegnimento (SEMPRE, in quest'ordine)

```bash
# 1) rimetti la security posture: Keycloak UI -> realm eurotransit -> Clients -> eurotransit-frontend
#    -> Direct access grants OFF -> Save
# 2) ferma il loop di traffico (Ctrl+C) e chiudi i port-forward (Ctrl+C nei loro terminali)
# 3) spegni il cluster e VERIFICA:
az aks stop -g $RG -n $CLUSTER
az aks show -g $RG -n $CLUSTER --query powerState.code -o tsv     # deve stampare: Stopped
```

---

## SE QUALCOSA NON VA (respira, è quasi sempre uno di questi)
| Sintomo | Causa | Rimedio |
|---|---|---|
| un curl torna **401** | il token dura 5 min | `mktoken` e riprova |
| un `localhost:PORT` non risponde | il port-forward è caduto | rilancia la riga del §5 in quel terminale |
| Prometheus irraggiungibile 1-2 min dopo l'avvio | l'operator sta riavviando il pod | aspetta, ricarica |
| `eurotransit` **OutOfSync** in Argo | campi runtime di Rollouts (pesi/selector) | è cosmetico: Health=Healthy basta |
| rollout fermo su "Progressing" | è in PAUSA tra gli step del canary | è il design: guarda step/pesi su :3100 |
| niente pallini exemplar | servono scrape freschi + traffico | lascia girare il loop 2-3 min e ricarica |
| ordini tutti REJECTED (SOLD_OUT) | trip esaurito | scegli un altro trip: `curl -sk "$APP/api/catalog/trips" -H "Authorization: Bearer $TOK"` |
| pod `Pending: Insufficient cpu/memory` | i 6 vCPU sono al limite (finding noto) | di solito rientra da solo (HPA scala giù); altrimenti guarda `kubectl describe pod <nome>` |
