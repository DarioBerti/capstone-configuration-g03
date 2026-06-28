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

Continue in FASE3_GUIDA_PRATICA.md ...

**Colleagues have to do**:
- az login
- if they have more than one subscription, pick the right one:
- az account set --subscription "Azure for Students"   # the 7c9b016c... one
- az aks get-credentials -g lab02_g03_group -n lab_g03_cluster
- kubectl get nodes