# Fase 5 — Progressive delivery (canary + blue/green) — cosa abbiamo fatto e perché

Documento per il team **e** per l'orale. Realizza il Pilastro D "consegna progressiva": due strategie sul
**percorso critico** (`/api/orders`), entrambe **GitOps-native** (lo stato del rollout vive in Git, Argo CD
riconcilia). Codice nel chart `eurotransit`; complementa la Fase 4 (le SLI guidano la promozione).

## Perché NON all-at-once / rolling sul money path
- **All-at-once**: sostituisci tutto subito → il 100% degli utenti vede la nuova versione all'istante. Un bug
  colpisce tutti.
- **Rolling** (default di un Deployment): sostituisce i pod gradualmente, ma **non controlli l'esposizione del
  traffico** né puoi *osservare* la nuova versione su una fetta piccola prima di estendere. È un rollout
  *infrastrutturale*, non *di traffico*.
- Sul checkout vogliamo **esposizione graduale guidata dalle SLI** → **canary** (rampa %) o **blue/green**
  (due ambienti, switch atomico). Entrambi danno **rollback rapido** senza ri-buildare.

## Decisione D9: TraefikService, non Argo Rollouts
Usiamo le CRD native di Traefik (`IngressRoute` + `TraefikService` pesata): il **peso del rollout sta in
`values.yaml`**, la promozione è un **commit** (umano, guardando le SLO). Argo Rollouts automatizzerebbe la
promozione (analysis runs) — lo citiamo come alternativa, ma per il capstone preferiamo il controllo esplicito
e la traccia in Git. Prerequisito: `providers.kubernetesCRD` abilitato in Traefik (`platform/traefik/values.yaml`).

## Refactor abilitante: un workload, due track (no drift)
Il corpo Deployment+Service è estratto in un template riusabile, così **stable e canary/green nascono dalla
STESSA definizione** (env/probe/risorse identici per costruzione). `templates/_workload.tpl`:
```gotemplate
{{- define "eurotransit.serviceWorkload" -}}
# args: root=$  name=<metadata+selector name>  svc=<config>  tag=<image tag>  [replicas]
...
  selector:
    matchLabels:
      {{- include "eurotransit.selectorLabels" (dict "svc" .name) | nindent 6 }}   # name = identità
        - image: "{{ .svc.image.repository }}:{{ .tag }}"                           # tag parametrico
...
{{- end -}}
```
`deployments.yaml` lo chiama per lo stable; `canary.yaml`/`bluegreen.yaml` per la seconda track. **Trucco
chiave:** `name` guida `app.kubernetes.io/name`, quindi le due track hanno **Service distinti e non
sovrapposti** (`orders` vs `orders-canary`/`orders-green`) → si può splittare il traffico **senza toccare il
selector (immutabile) dello stable**.

## Canary (rampa pesata)
`templates/canary.yaml` rende `orders-canary` (stessa config/db/oidc dello stable, **tag canary**, repliche
fisse, niente HPA). `templates/ingressroute-orders.yaml` fa lo split:
```yaml
kind: TraefikService
metadata: { name: orders-weighted }
spec:
  weighted:
    services:
      - { name: orders,        port: 8080, weight: {{ sub 100 $w }} }   # stable
      - { name: orders-canary, port: 8080, weight: {{ $w }} }           # canary
---
kind: IngressRoute            # /api/orders -> la TraefikService pesata
spec:
  routes:
    - match: Host(`...`) && PathPrefix(`/api/orders`)
      services: [{ name: orders-weighted, kind: TraefikService }]
  tls: { secretName: eurotransit-tls }
```
**Promozione GitOps**: in `values.yaml`
```yaml
services.orders.canary: { enabled: true, tag: <nuovo-sha>, weight: 5, replicaCount: 1 }
```
si alza `weight` **5 → 50 → 100** (un commit per step) **osservando le SLO** della Fase 4 (success-rate intake,
ack p99). **Rollback** = `weight: 0` (o `enabled: false`) e commit. Quando il canary è attivo, l'Ingress
standard **molla** `/api/orders` (lo prende la IngressRoute).

## Blue/green (due ambienti, switch atomico)
Alternativa al canary (**mutuamente esclusivi**: il chart fa `fail` se accendi entrambi — entrambi possiedono
`/api/orders`). `blue` = lo stable `orders`; `green` = `orders-green` a **piena capacità** (stesso `replicaCount`).
`templates/bluegreen.yaml`:
```yaml
kind: IngressRoute            # 100% al colore ATTIVO
spec:
  routes:
    - services:
        - name: {{ if eq $active "green" }}orders-green{{ else }}orders{{ end }}
          port: 8080
```
`values.yaml`:
```yaml
services.orders.bluegreen: { enabled: true, greenTag: <candidato>, active: blue }  # blue|green
```
**Release** = flip `active: blue → green` + commit → **cutover atomico** del 100%. **Rollback** = flip back
(istantaneo: il colore vecchio è ancora su). Finché `active=blue`, green gira ma riceve **0 traffico pubblico**
→ lo smoke-testi internamente (Service `orders-green` raggiungibile in-cluster) prima dello switch.

**Canary vs blue/green (per l'orale):** canary = *rampa* di una piccola % per osservare sotto carico reale, poco
costoso in risorse; blue/green = *due ambienti pieni* con switch 100% istantaneo (rollback immediato, ma doppia
capacità durante la finestra). Stesso meccanismo di routing (IngressRoute), politica diversa.

## File toccati
- `templates/_workload.tpl` (nuovo — define riusabile) · `templates/deployments.yaml` (usa il define)
- `templates/canary.yaml`, `templates/ingressroute-orders.yaml` (nuovi — canary)
- `templates/bluegreen.yaml` (nuovo — blue/green) · `templates/ingress.yaml` (molla `/api/orders` se canary/bg on)
- `values.yaml` (`services.orders.canary` + `services.orders.bluegreen`) · `platform/traefik/values.yaml` (`kubernetesCRD`)

## Validazione
`helm lint` pulito; render base **invariato** (route standard); canary ON → `orders-canary` + `TraefikService`
(pesi 95/5, verificati anche 50/50) + `IngressRoute`; blue/green ON → `orders-green` + `IngressRoute` al colore
attivo (switch blue↔green ok); accendere entrambi → errore di render voluto.
