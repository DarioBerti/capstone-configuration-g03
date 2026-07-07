# Team roles — EuroTransit (g03)


**Team:** Dario Berti · Emanuele Romano · Mattia Domizio · Federico Ferrari · Riccardo Mozzicato

| Member | Primary focus | Evidence (git history + docs) |
|---|---|---|
| **Mattia Domizio** | Initial backend, delivery owner, chaos testing and docs | Most commits in both repos. Owns the oral/graded track (FASI_PROGETTO, the two READMEs, DoD, agent-log, threat-model, version matrix); Argo Rollouts canary + blue/green (Phase 5); chaos runbooks + their live execution on AKS (Phase 6); constrained-cluster tuning. |
| **Riccardo Mozzicato** | Frontend and backend | The booking rework merged to `main`: PayPal PSP behind the payment gateway, SSE saga-status stream, order-legs + checkout hold window, the storefront SPA. |
| **Emanuele Romano** | Application resilience and deployment | Phase 2 resilience (circuit breaker / bulkhead / retry, expired-reservation compensation); Phase 4 observability (saga-completion SLI, Kafka/CDC dashboards, cross-Kafka tracing + `traceparent`, DLT/CDC/slot scraping & alerts); canary-gate hardening. |
| **Dario Berti** | Platform / cluster bring-up and Observability owner | Phase 3 on AKS: Traefik / cert-manager / Strimzi / CloudNativePG, Let's Encrypt staging+prod TLS (sslip.io host), node-count + CNPG sizing, Argo CD repoURL, CI → real registry. Hosts both GitHub repos. |
| **Federico Ferrari**  | Data and verification owner | Database schema design, Flyway migration scripts, verification tests. SLO validation. |

**Shared ownership (whole team).** Per the capstone rule, the team owns every engineering
*judgment*: service decomposition, the consistency model (PACELC / RPO), SLO definitions,
failure-mode mapping, chaos hypotheses, and the blameless postmortem.
