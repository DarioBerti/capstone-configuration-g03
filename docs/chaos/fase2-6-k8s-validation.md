# Fase 2 §6 — Validazione Kubernetes live (evidenze)

**Cluster:** `lab_g03_cluster` (AKS, 3× nodi `aks-etpool-…vmss00000{c,d,e}`, k8s v1.33) · **Data:** 2026-06-28
**Namespace app:** `eurotransit` · **Ingress:** `https://158.158.71.17.sslip.io` (Traefik + Let's Encrypt prod)
**ArgoCD:** `Synced & Healthy` prima e dopo i test.

Gli artefatti (probe/PDB/topology/HPA/graceful-shutdown) sono nel chart `eurotransit` (Fase 0/1); qui si **prova
che funzionino col codice** sul cluster reale. Nessuna modifica di codice in §6.

## Esiti

| # | Check | Esito | Evidenza |
|---|---|---|---|
| 6.1 | Probe deliberate | ✅ | `curl /actuator/health/readiness` = `{"components":{"db":{…UP},"readinessState":{…UP}},"status":"UP"}` → **niente kafka**. `/liveness` = `{"status":"UP"}` (solo stato processo). readiness ≠ liveness. |
| 6.2 | PodDisruptionBudget | ✅ | `kubectl drain …00000c`: app eurotransit evictate **una alla volta** rispettando il PDB (`get deploy` resta 2/2, money-path mai a 0). Osservati i rifiuti `Cannot evict pod as it would violate the pod's disruption budget` su `eurotransit-dual-role-1` (Kafka), coredns, metrics-server, konnectivity. CNPG `orders-db` failover pulito (primary → `orders-db-2`). `uncordon` → tutto Ready. |
| 6.3 | Topology spread | ⚠️ **finding** | `topologySpreadConstraints{maxSkew:1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway}` su orders/inventory/payments. Live: **entrambe le payments su `…00000d`** → lo spread soft non garantisce la distribuzione. Vedi sotto. |
| 6.4 | HPA mirato | ✅ | `kubectl get hpa` = **solo** `catalog` (cpu 2%/70%) e `orders` (cpu 4%/70%), min2/max4. inventory/payments/notifications **senza** HPA (collo di bottiglia = DB/PSP, non CPU). Scale-up live non eseguito (costo AKS) — la scelta di design è l'acceptance. |
| 6.5 | Graceful shutdown | ✅ | Kill di una replica `orders` sotto traffico money-path continuo: **45/45 richieste `202`**, zero 5xx (deploy resta 2/2). Log del pod morente: `Commencing graceful shutdown. Waiting for active requests to complete` → `cancelling outbox relay (cooperative shutdown)` (OutboxPublisher) → `cancelling order recovery sweep (cooperative shutdown)` (OrderRecoverySweeper). `terminationGracePeriodSeconds:30` + `preStop: sleep 5` confermati nel manifest. |
| 6.6 | Degradazione | ✅ | `kubectl scale deploy notifications --replicas=0` → `0/0`; `POST /api/orders` (`TRENO-TO-MI-0800`) → `PENDING` → **`CONFIRMED`** in ~4s. Checkout completa con Notifications interamente giù. notifications ripristinato a 1/1. |

## Finding §6.3 — topology spread soft (scelta team)
`whenUnsatisfiable: ScheduleAnyway` rende lo spread una **preferenza**, non una garanzia → su questo run lo scheduler
ha co-locato entrambe le repliche `payments` sullo stesso nodo. Un guasto di quel nodo perderebbe tutta la capacità
payments (*"replication protects only if replicas are across independent failure domains"*).
**Opzione:** `DoNotSchedule` (hard) garantirebbe nodi distinti, ma su 3 nodi rischia pod non-schedulabili durante un
drain/upgrade. **Trade-off availability vs hard-spread → decisione del team** (annotare in `docs/design.md`). Non
modificato dall'agente. Tracciato in `agent-log.md #16`.

## Nota osservata (non un bug)
- **Restart 3-4/pod** all'inizio sessione: `lastState.terminated.reason=Error exitCode=143` = **SIGTERM** (128+15),
  da `az aks start` che ciclava i nodi — **non OOMKilled**. Benigno; è anche prova che l'handling SIGTERM funziona.
- **§7.5 structured logging non ancora live:** i pod girano l'immagine Fase 3 (`3af035e`), precedente alla config
  `logging.structured.format.console=ecs` → log live in plain. JSON ECS dopo rebuild CI. Meccanismo provato in
  locale da `OrdersStructuredLoggingTest`.

## Costo
Validazione conclusa → `az aks stop --name lab_g03_cluster --resource-group lab02_g03_group` → power state **Stopped**
(billing nodi fermo). Riavvio: `az aks start …` (~5 min).
