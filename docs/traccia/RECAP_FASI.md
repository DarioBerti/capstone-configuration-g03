# EuroTransit — Recap Fasi 1-4 (cosa, come, e perché — con il codice vero)

Documento di riferimento per il team **e** per l'orale (la domanda tipica: *"che approccio implementativo avete
seguito e perché?"*). Per ogni scelta importante c'è una **finestrella di codice reale** (presa dai file definitivi:
backend dal branch `dev` post-rework, chart/piattaforma da `configuration/main`) e la spiegazione delle scelte di
**design** e di **implementazione** (fin nella sintassi).

> Stato/avanzamento → `FASI_PROGETTO.md` · 12 decisioni con rationale → `docs/design.md` · SLI/SLO → `docs/slo.md`.

**Sistema:** marketplace di biglietti treno, 5 microservizi Kotlin 2.2.21 / Spring Boot 4.0.3 / JDK 21
(`catalog`, `orders`, `inventory`, `payments`, `notifications`; + `users` con Keycloak nel rework). Modello **GitOps**
a 2 repo: `application` (codice) + `configuration` (stato desiderato, riconciliato da Argo CD). Si viene valutati sul
**comportamento operativo sotto guasto parziale**.

### Principi trasversali (da dire all'orale, valgono per tutte le fasi)
1. **Idempotenza ovunque** sul money path (vincoli `UNIQUE`, UPDATE condizionali) → l'at-least-once di Kafka è sicuro.
2. **Contenere il guasto, non propagarlo**: breaker aperto / 429 / bulkhead pieno sono il sistema che *funziona*
   (rifiuto controllato), quindi **non** devono mai influenzare readiness/health.
3. **GitOps come unica verità**: nessuno tocca il cluster a mano; si cambia Git e Argo allinea.
4. **Osservabilità sui sintomi**: si misura/allarma su ciò che vede l'utente (SLO), non sulle risorse.
5. **Resilience4j**: il gateway (breaker/bulkhead/retry) è decorato **programmaticamente** via registry — scelta
   deliberata per ordinare la composizione `Retry(CircuitBreaker(Bulkhead))`, evitare la self-invocation ed essere
   testabile in modo deterministico; l'intake usa l'**annotazione `@RateLimiter`** (su Boot 4 le annotazioni ora
   fanno weave, resilience4j 2.4.0 / `resilience4j-spring-boot4` — vedi `agent-log` #2).

---

## Fase 1 — Core money path

Logica di dominio dei 5 servizi. Tre invarianti del money path: **never oversell**, **no doppio addebito**,
**nessun evento perso**. Sono codificate, non sperate.

### 1a. "Never oversell" = UPDATE condizionale atomico (Inventory)
`services/inventory/.../repository/TripSeatsRepository.kt`:
```kotlin
@Modifying(clearAutomatically = true, flushAutomatically = true)
@Query("""
    update TripSeats t
       set t.available = t.available - :qty,
           t.updatedAt  = current_timestamp
     where t.tripCode   = :tripCode
       and t.available  >= :qty
    """)
fun tryDecrement(@Param("tripCode") tripCode: String, @Param("qty") qty: Int): Int
```
**Design:** la prenotazione del posto è un **singolo UPDATE condizionale** (`... AND available >= :qty`). È atomico
sotto l'isolamento del DB: due transazioni concorrenti sull'ultimo posto vengono **serializzate dal row-lock**, e chi
perde vede il valore già decrementato → `0 righe aggiornate = sold out`. È la nostra scelta **CP** (consistenza prima
della disponibilità) resa eseguibile, senza lock applicativi.
**Implementazione (sintassi):** il metodo **ritorna `Int`** = righe aggiornate (1 prenotato / 0 esaurito), così il
service decide senza una seconda query. `flushAutomatically = true` forza il flush delle modifiche pendenti (es. una
transizione di stato impostata appena prima) *prima* della bulk-update — senza, `clearAutomatically` le scarterebbe
silenziosamente (bug preso da un test). `updatedAt` è bumpato nello stesso statement.

### 1b. "No doppio addebito" = idempotenza stretta su `UNIQUE(order_id)` (Payments)
`services/payments/.../service/PaymentsServiceImpl.kt`:
```kotlin
@Transactional
override fun authorize(orderId: String, amountCents: Long): AuthorizeOutcome {
    require(amountCents > 0) { "amountCents must be positive" }

    authorizations.findByOrderId(orderId)?.let {          // fast-path: già autorizzato
        outcomes("replayed").increment()
        return AuthorizeOutcome(it, replayed = true)      // replay dell'esito, non si addebita nulla
    }
    // ... altrimenti decide (mock PSP) e inserisce una PaymentAuthorization ...
}
```
**Design:** stessa forma dell'Inventory. **Fast-path**: se esiste già un'autorizzazione per quell'`orderId`, ritorna
l'esito memorizzato (una chiamata ripetuta è un **no-op**). **Race-path**: se due duplicati superano insieme il
pre-check, il vincolo **`UNIQUE(order_id)`** lascia committare **un solo** insert; la transazione perdente (addebito
incluso) fa rollback e al retry replaya l'esito salvato. → exactly-one per ordine anche con redelivery.

### 1c. "Nessun evento perso" = Outbox transazionale (Orders)
`services/orders/.../service/Outbox.kt`:
```kotlin
fun append(topic: String, aggregateId: String, payload: Any) {
    repository.save(
        OutboxEvent(
            topic = topic,
            aggregateId = aggregateId,
            eventType = payload::class.simpleName,
            payload = objectMapper.writeValueAsString(payload),
        ),
    )
}
```
**Design:** `append()` **deve** girare dentro la `@Transactional` del chiamante: il cambio di stato di business e
il suo evento **committano o fanno rollback insieme**. Niente "scrittura persa" (cambio salvato ma evento mai
pubblicato). Un **relay** separato legge le righe `published_at IS NULL` e le pubblica su Kafka (at-least-once); i
consumer sono idempotenti (vedi 1a/1b), quindi una redelivery è sicura. La POST ritorna **202 Accepted** subito
(ack durevole), e reserve→authorize→confirm procede in modo asincrono (saga).

---

## Fase 2 — Resilienza applicativa (Pilastro C)

Obiettivo: su `Orders → Payments/Inventory`, **contenere** il guasto. Tutte le policy in un punto solo.

### 2a. Composizione Resilience4j programmatica: `Retry(CircuitBreaker(Bulkhead(call)))`
`services/orders/.../gateway/GatewayResilience.kt`:
```kotlin
private fun <T> decorate(instance: String, useBreaker: Boolean, block: () -> T): T {
    // Compone innermost -> outermost: a runtime diventa Retry( CircuitBreaker( Bulkhead( block ) ) )
    var callable: Callable<T> = Bulkhead.decorateCallable(bulkheads.bulkhead(instance), Callable { block() })
    if (useBreaker) {
        callable = CircuitBreaker.decorateCallable(circuitBreakers.circuitBreaker(instance), callable)
    }
    callable = Retry.decorateCallable(retries.retry(instance), callable)
    return callable.call()
}
```
**Design:** ordine canonico **Retry → CircuitBreaker → Bulkhead**. Conseguenze volute: breaker aperto → l'inner lancia
`CallNotPermittedException`, che **non** è tra le retry-exceptions → **fast-fail, niente retry-storm**; bulkhead pieno →
`BulkheadFullException`, ignorata dal breaker (un cap di concorrenza locale non deve da solo aprire il breaker); Retry
**esterno** = ogni tentativo è un punto-dato per il breaker, che apre prima sotto guasto sostenuto. Il breaker si mette
**solo su Payments** (`callWithBreaker`), non su Inventory (`call`): Inventory è la risorsa contesa, non un coordinatore
del money path.
**Implementazione (sintassi):** si applica **programmaticamente** via i registry iniettati
(`Bulkhead.decorateCallable(...)`, ecc.), **non** con `@CircuitBreaker`/`@Bulkhead`: l'aspect AOP dello starter non è
garantito agganciarsi su Boot 4 (agent-log #2), mentre i bean registry sono verificati nei test → decorazione
deterministica. L'ordine è dato dal **wrapping**: `.decorateCallable` applicato per primo finisce più interno.

### 2b. Le soglie come policy in `application.yml` (non magic number nel codice)
`services/orders/.../resources/application.yml`:
```yaml
resilience4j:
  circuitbreaker:
    instances:
      payments:
        failure-rate-threshold: 50          # apre se >50% FAILED nella finestra
        slow-call-duration-threshold: PT2S  # una call >2s conta come "slow"
        slow-call-rate-threshold: 50        # ...o se >50% sono slow (i due criteri del prof)
        wait-duration-in-open-state: PT10S
  retry:
    instances:
      payments: { max-attempts: 3, wait-duration: PT0.2S, enable-exponential-backoff: true, enable-randomized-wait: true }
  bulkhead:
    instances:
      payments: { max-concurrent-calls: 8, max-wait-duration: PT0S }   # PT0S = niente coda, fail-fast
```
**Design:** soglie = **decisione di team** (design.md dec. 7), tunabili senza ricompilare. Retry breve+jitter
(de-sincronizza i client, anti-storm); bulkhead **semaforo** con `max-wait PT0S` = rifiuto immediato, niente coda.

### 2c. Backpressure 429 al solo edge
`services/orders/.../controller/OrdersController.kt`:
```kotlin
@RateLimiter(name = "orders-intake")   // resilience4j-spring-boot4 + spring-boot-starter-aop
@PostMapping
fun place(...): ResponseEntity<OrderResponse> {
    // oltre budget l'aspect lancia RequestNotPermitted PRIMA di questo corpo (DB/outbox intatti);
    // GlobalExceptionHandler la mappa a 429 + Retry-After e incrementa orders_intake_shed_total
    ...
}
```
**Design:** "backpressure non è fallimento, è rifiuto controllato; le code ritardano solo il fallimento". Sotto
sovraccarico la POST `/api/orders` risponde **429 + Retry-After** invece di accodare fino al collasso. Lo shedding è
**solo all'edge**: le chiamate interne del saga sono governate da breaker/bulkhead, mai da un 429.
**Implementazione:** `Retry-After` è **derivato** dalla finestra del limiter (non un numero magico) → header e limiter
non possono divergere. Qui usiamo l'annotazione `@RateLimiter` (a differenza del gateway, non c'è composizione da
ordinare né self-invocation). La metrica `orders_intake_shed_total` è **senza label ad alta cardinalità** (no
orderId/userId) — "le label ad alta cardinalità distruggono i sistemi di metriche".

> Inoltre (sempre Fase 2): fallback **`PAYMENT_PENDING`** quando il breaker è aperto (l'ordine non è né rifiutato né
> appeso) + un **recovery sweeper** che lo drena quando Payments torna, o lo rigetta entro il TTL del hold (così non si
> addebita mai una carta per un posto già restituito); compensazione **refund/void** su prenotazione scaduta.

---

## Fase 3 — Piattaforma sul cluster reale (GitOps)

Il sistema gira su AKS (`lab_g03_cluster`, 3× B2s_v2), riconciliato da Argo CD. `values.yaml` è il **pannello di
controllo**: un template genera tutto per ogni servizio.

### 3a. Un template, N servizi — il loop guidato dai flag
`deploy/charts/eurotransit/templates/deployments.yaml`:
```yaml
{{- range $name, $svc := .Values.services }}      # 1 Deployment + Service per entry di .Values.services
        - name: {{ $name }}
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: "cluster"
            - name: MANAGEMENT_OTLP_TRACING_ENDPOINT
              value: {{ $.Values.global.otlpEndpoint | quote }}   # $ = root del chart dentro il range
            {{- if $svc.usesKafka }}
            - name: KAFKA_BOOTSTRAP
              value: {{ $.Values.global.kafkaBootstrap | quote }}
            {{- end }}
            {{- if $svc.secured }}                  # OAuth2 resource server -> OIDC env
            - name: KEYCLOAK_ISSUER
              value: {{ $.Values.global.oidc.issuer | quote }}
            {{- end }}
{{- end }}
```
**Design:** in `values.yaml` ogni servizio ha flag (`criticalPath`, `hpa.enabled`, `secured`, `usesKafka`) che
pilotano PDB / topology-spread / HPA / env. Un solo template → coerenza garantita, niente drift tra servizi.
**Implementazione (sintassi):** dentro `{{- range $name, $svc := ... }}` il contesto `.` è il servizio, quindi per la
root si usa **`$`** (es. `$.Values.global.kafkaBootstrap`); i blocchi `{{- if $svc.usesKafka }}` iniettano env solo a
chi serve.

### 3b. CloudNativePG con replica sincrona dove vive l'invariante
`deploy/charts/eurotransit/values.yaml`:
```yaml
databases:
  inventory-db:
    instances: 3                # primary + 2 standby: sopravvive alla perdita di 1 senza bloccare le scritture
    synchronous:
      method: any
      number: 1                 # ANY 1 di 2 standby deve confermare
      dataDurability: required  # consistenza > disponibilità: blocca le scritture piuttosto che rischiare RPO>0
```
**Design:** è il nostro statement **PACELC** reso reale. CNPG di default replica **async** (RPO>0): un failover potrebbe
perdere l'ultima prenotazione committata → "never oversell" violato. Per `inventory-db` mettiamo replica **sincrona
`required`** → **RPO=0** sempre (chaos #5). `orders-db` usa `preferred` (RPO=0 in salute, ma degrada ad async invece di
bloccare l'intake se la standby sparisce); `payments-db`/`catalog-db` singola istanza (correttezza via idempotenza /
tollera staleness).

### 3c. CI → GitOps: bump del tag immutabile, senza credenziali del cluster
`application/.github/workflows/ci.yml`:
```yaml
- name: Bump image tags for built services
  run: |
    for s in $(echo "$SERVICES" | yq -p=json -o=tsv '.[]'); do
      yq e ".services.${s}.image.tag = \"${SHA}\"" -i "$VALUES"   # bumpa SOLO image.tag, non il repository
    done
- run: |
    git commit -m "ci: bump image tags to ${SHA}"
    git push                                                      # Argo CD riconcilia il nuovo tag
```
**Design:** la CI builda+testa, pusha l'immagine **taggata col commit SHA** (immutabile) su ACR, poi aggiorna lo stato
desiderato nel repo `configuration`. La CI **non ha mai credenziali del cluster**: scrive solo via un PAT
**least-privilege** (write sul solo config repo) — è il "ponte" GitOps. Argo CD fa il resto; drift dimostrato con
**selfHeal** + **prune**.

---

## Fase 4 — Observability (Pilastro D)

Metriche, SLO, dashboard, log, tracing. Validato live su AKS (la pipeline tracing montata su kind).

### 4a. ServiceMonitor per ogni servizio (auto-copertura)
`deploy/charts/eurotransit/templates/observability.yaml`:
```yaml
{{- range $name, $svc := .Values.services }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ $name }}
  labels:
    release: {{ $release }}              # label su cui il kube-prometheus-stack "adotta" il monitor
spec:
  endpoints:
    - port: http
      path: /actuator/prometheus         # Micrometer -> Prometheus
      interval: 15s
{{- end }}
```
**Design:** stesso loop `range .Values.services` dei Deployment → quando il rework aggiunge `users`, il suo
ServiceMonitor **compare da solo**. La label `release` è ciò che la stack Prometheus matcha per adottare la CR.

### 4b. SLO del checkout: recording rule + alert burn-rate multi-finestra
stesso file, `PrometheusRule`:
```yaml
- record: checkout_intake:error_ratio:rate5m
  expr: |
    sum(rate(http_server_requests_seconds_count{uri="/api/orders", method="POST", status=~"5.."}[5m]))
      /
    sum(rate(http_server_requests_seconds_count{uri="/api/orders", method="POST"}[5m]))
- alert: CheckoutIntakeErrorBudgetBurnFast
  expr: |
    checkout_intake:error_ratio:rate1h / (1 - 0.99) > 14.4
      and
    checkout_intake:error_ratio:rate5m / (1 - 0.99) > 14.4
  for: 2m
  labels: { severity: page, slo: checkout-success-rate }
```
**Design:** lo SLO è costruito sulla metrica **standard** `http_server_requests_seconds*` (non su metriche di dominio)
→ **sopravvive al rework**. Un **429 NON è errore** (`status=~"5.."` esclude i 4xx): il rifiuto controllato non brucia
budget. Alert **burn-rate multi-finestra** (fast 1h&5m ×14.4, slow 6h&30m ×6): si paga (page) solo quando una finestra
**lunga e una corta** bruciano insieme → meno falsi allarmi. Si allarma **solo sui sintomi** utente, mai su CPU/breaker.
**Implementazione:** il `(1 - 0.99)` = error budget (1 − target); `14.4` = consumare in ~2 giorni il budget mensile.

### 4c. Tracing: app backend-agnostiche → gateway OTel → Tempo
app `application.yml` (lato servizio):
```yaml
management:
  tracing:
    sampling: { probability: 1.0 }                 # demo: traccia tutto
  otlp:
    tracing:
      endpoint: http://localhost:4318/v1/traces    # in-cluster sovrascritto da MANAGEMENT_OTLP_TRACING_ENDPOINT
```
`platform/observability/otel-collector.yaml` (pipeline del Collector):
```yaml
service:
  pipelines:
    traces:
      receivers:  [otlp]          # le app spediscono OTLP 4318 al Collector
      processors: [batch]         # batching in un punto solo
      exporters:  [otlp/tempo]    # export verso Tempo (datasource Grafana)
```
**Design:** i servizi conoscono solo "manda OTLP a `otel-collector`"; **batching/sampling/routing** stanno in un punto
solo (il gateway Collector). Il Service è chiamato `otel-collector` in ns `observability` **apposta**, così l'endpoint
già iniettato nei Deployment risolve senza modifiche.
**Stato:** pipeline provata su kind; la traccia distribuita live è **TODO backend** (fix del wiring trace-export su
Boot 4, su `dev`) — le metriche funzionano, gli span no, quindi è un problema applicativo non di config.

### 4d. Log e dashboard
Log **strutturati ECS JSON** su stdout (profilo `cluster`) con `traceId`/`spanId` per correlare log↔trace. Dashboard
**as-code** (ConfigMap caricate dalla sidecar Grafana): **RED** per servizio + **Runtime/golden-signals** JVM; **USE**
infra dalle dashboard native di kube-prometheus; Kafka-lag e CNPG pronte ma gated finché non si abilitano gli exporter
(niente pannelli vuoti).

---

## TODO / aperti a valle della Fase 4
- **Tracing live** → fix trace-export Boot 4, lato backend su `dev` (Riccardo). Traccia + screenshot lì (utile demo Fase 6).
- **Capacità AKS**: 3× B2s_v2 (6 vCPU) saturi di CPU-*requests* con observability completa → su cluster non stanno
  insieme HA al completo + tracing/chaos; si gira su kind o si alza temporaneamente il node pool.
- **Chaos engineering** (5 esperimenti) = **Fase 6**, non 4.
