# Argo Rollouts — progressive delivery controller (Fase 5)

Il controller che **esegue** la nostra release policy sul money path. Sostituisce il canary/blue-green
"manuale" (peso editato in Git guardando Grafana): la policy resta dichiarata in Git (step, pause, soglie,
query — nel chart), l'**esecuzione** — spostare i pesi, interrogare Prometheus, promuovere o abortire — è
del controller. Ogni bump di `image.tag` fatto dalla CI diventa così un rilascio progressivo **gated sulle
SLO**, senza umani nel loop.

```text
CI (app repo) ──bump image.tag──► config main ──Argo CD──► Rollout vede il nuovo template
   └─► steps: 5% ──2m──► 25% ──2m──► 50% ──5m──► 100%          (pesi sulla TraefikService orders-weighted)
        ▲ background AnalysisRun ogni 30s (success-rate, ack p99, consumer failures — canary-scoped)
        └─ analisi KO ──► ABORT: peso a 0, traffico tutto sullo stable, release ferma (rollback automatico)
```

## Componenti

| Pezzo | Dove | Ruolo |
|---|---|---|
| Controller + dashboard | questa app ([argo-rollouts-application.yaml](../argocd/argo-rollouts-application.yaml), chart `argo-rollouts` **2.41.0** = app **v1.9.0**, ns `argo-rollouts`) | esegue le strategie |
| `Rollout` orders | chart eurotransit (`_workload.tpl` via `services.orders.rollout`) | il workload (al posto del Deployment) |
| `orders-canary` Service + `orders-weighted` TraefikService + IngressRoute | chart (`progressive-delivery.yaml`) | lo split del traffico `/api/orders` |
| `AnalysisTemplate orders-canary-slo` | chart (`analysis.yaml`) | il giudizio automatico (query Fase 4 canary-scoped) |
| `ignoreDifferences` | [eurotransit-application.yaml](../argocd/eurotransit-application.yaml) | Argo CD non combatte i campi runtime del controller |

**Flag Traefik obbligatori** (v3 = gruppo API `traefik.io`; il default del controller è ancora il ritirato
`traefik.containo.us` → senza flag ogni lookup della TraefikService fallisce): `--traefik-api-group=traefik.io
--traefik-api-version=traefik.io/v1alpha1` (supportati dal v1.7, argo-rollouts#3119).

## Le due strategie (per orders — `services.orders.rollout.strategy`)

- **`canary`** (default): ramp 5→25→50→100 sulla TraefikService pesata. `canaryReplicas: 1` nei primi step
  limita l'esposizione **lato consumer Kafka** (v. sotto); `matchTrafficWeight` la rilascia al 50%.
  Con `analysis.enabled` la promozione è SLO-gated; senza (kind), gate = solo le pause.
- **`bluegreen`**: preview a piena capacità accanto all'attivo; smoke-test in-cluster su
  `http://orders-preview:8080`; `kubectl argo rollouts promote orders` flippa **atomicamente** il selector
  della Service `orders` (nessun oggetto Traefik coinvolto); rollback = `undo`.

**⚠️ Semantica async (vale per entrambe):** i pod canary/preview condividono il **consumer group Kafka** con
lo stable — il peso HTTP governa solo l'intake; le reply della saga le consumano anche i pod nuovi (la
preview a piena capacità ne consuma ~metà PRIMA della promozione). L'invariante di release è la
**compatibilità degli eventi tra versioni**; l'analysis sorveglia anche il failure-rate dei listener del
canary. Dettaglio: `docs/design.md §4-D`.

## Operatività

```bash
# vista live (kubectl-plugin) — step, pesi, analysis:
kubectl argo rollouts -n eurotransit get rollout orders --watch
# dashboard web (alternativa senza plugin):
just rollouts-dashboard          # -> http://localhost:3100
# gate manuali:
kubectl argo rollouts -n eurotransit promote orders     # salta la pausa corrente / promuove il preview
kubectl argo rollouts -n eurotransit abort orders       # peso a 0, tutto sullo stable
kubectl argo rollouts -n eurotransit undo orders        # torna alla revision precedente
# stato analysis dell'ultima run:
kubectl -n eurotransit get analysisrun
```

Install locale (kind): `just rollouts-install` (incluso in `bootstrap-kind`). Su kind l'analysis è OFF
(niente Prometheus) e il ramp è compresso (30s) — v. `values-kind.yaml`.

## Perché non (più) il peso manuale — e i trade-off accettati

Il meccanismo precedente (peso della TraefikService editato in Git) era GitOps-puro ma il "controller" che
decideva promote/rollback era un umano su Grafana: infrastruttura di delivery fatta a mano, e nessuna
reazione automatica a un canary che brucia error budget. Trade-off accettati con Rollouts:
1. il Deployment di orders diventa un CRD `Rollout` (stesso pod template, da `_workload.tpl`);
2. pesi/selector sono campi runtime del controller → `ignoreDifferences` + `RespectIgnoreDifferences`
   nell'app Argo CD (pattern documentato Argo CD↔Rollouts; l'audit della promozione passa dagli eventi
   del Rollout e dalle AnalysisRun, la policy resta versionata in Git);
3. il router Traefik di Rollouts è meno battle-tested di Istio/Nginx → validato E2E su kind prima del
   merge; piano B documentato: plugin Gateway API (argoproj-labs) + provider Gateway API di Traefik v3.
