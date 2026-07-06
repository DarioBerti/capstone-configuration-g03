# EuroTransit — Version & compatibility matrix

> Single reference for the versions the system is built and run against, and **why they cohere**. Two kinds of
> pin live here: (a) versions **hard-coded in the repos** (build files, image tags, Argo `targetRevision`),
> which are authoritative — and (b) components installed once on the cluster whose version is **not yet pinned
> in Git** (marked ⚠️ *confirm on cluster*), a reproducibility gap worth closing (the platform rule is
> "never `latest`"). Update this file whenever a build file or an image tag changes.
>
> Sources: app `services/*/build.gradle.kts` + `gradle/wrapper` + `frontend/package.json`, config `platform/*`,
> `deploy/charts/eurotransit`. Companion docs: the two repo READMEs + `docs/design.md` + `docs/agent-log.md`.

## 1. Language, build & runtime toolchain (application repo)

| Component | Version | Pinned in | Notes |
|---|---|---|---|
| Kotlin (JVM, `plugin.spring`, `plugin.jpa`) | **2.2.21** | each `build.gradle.kts` | one wrapper per service; `-Xjsr305=strict` |
| Spring Boot | **4.0.3** | each `build.gradle.kts` | Boot 4 is modularized — tracing/kafka/flyway auto-config moved out of actuator into dedicated starters (§5) |
| Spring dependency-management plugin | **1.1.7** | each `build.gradle.kts` | imports the Boot BOM → most deps are version-less & mutually compatible |
| JDK toolchain | **21** (`JavaLanguageVersion.of(21)`) | each `build.gradle.kts` | Gradle auto-provisions if absent |
| Gradle (wrapper) | **9.3.1** | `gradle/wrapper/gradle-wrapper.properties` | per-service wrapper, no root build |
| Jackson | **3.x** (`tools.jackson`) | Boot BOM | Boot 4 moved to Jackson 3 (`tools.jackson`, not `com.fasterxml`) |
| Hibernate / Spring Data JPA | Boot BOM | Boot BOM | `ddl-auto: validate` only; Flyway owns the schema |
| Flyway | Boot BOM (`spring-boot-starter-flyway` + `flyway-database-postgresql`) | Boot BOM | Boot 4 needs the *starter* to auto-migrate — bare `flyway-core` does not |
| PostgreSQL JDBC driver | Boot BOM (`org.postgresql:postgresql`) | Boot BOM | — |
| Testcontainers (postgresql, junit-jupiter) | Boot BOM | Boot BOM | real Postgres in tests, no H2 |
| **Resilience4j** (`-spring-boot4`, `-kotlin`, `-micrometer`) | **2.4.0** | `orders` + `payments` `build.gradle.kts` | the Boot-4 line (needs `spring-boot-starter-aspectj` for annotation weaving). Uses: the `@RateLimiter` intake shed (orders) and the `@CircuitBreaker`/`@Retry` around the PayPal PSP egress (payments) |

## 2. Platform operators & infrastructure (configuration repo)

| Component | Version | Pinned in | Notes |
|---|---|---|---|
| **Strimzi** (Kafka operator) | **1.1.0** | `platform/strimzi/kafka.yaml`, `platform/debezium/Dockerfile` | 1.x = **KRaft-only via KafkaNodePool** (no ZooKeeper) |
| **Apache Kafka** (broker) | **4.3.0** | `platform/strimzi/kafka.yaml` (`spec.kafka.version`) | API `kafka.strimzi.io/v1` |
| **CloudNativePG** (operator) | **1.29.1** | `platform/README.md` | **≥1.25 required** for `postgresql.synchronous` (inventory/orders RPO=0) |
| **PostgreSQL** (managed by CNPG) | **16** | CNPG `Cluster` CRs (`templates/databases.yaml`) | **DECISION: stay on PG16, no PG17 failover-slots** — the logical slot dies with the primary; the sweeper self-heals the money path, only best-effort notifications can be lost |
| **Debezium** (Postgres connector) | **3.0.0.Final** | `platform/debezium/Dockerfile` (`DEBEZIUM_VERSION`) | log-based CDC drains the outbox off the WAL |
| Debezium Connect image (ours) | **`eurotransit/debezium-connect:1.0.0`** | `platform/debezium/Dockerfile` (built by CI on demand) | 2 replicas (HA); built **FROM `quay.io/strimzi/kafka:1.1.0-kafka-4.3.0`** so the Strimzi Connect entrypoint + metrics agent line up; connectors declared as `KafkaConnector` CRs |
| **Argo Rollouts** | chart **2.41.0** = app **v1.9.0** | `platform/argocd/argo-rollouts-application.yaml` | **≥ app v1.7 required** for the `--traefik-api-group=traefik.io` flags |
| **OTel Collector** (gateway) | **`otel/opentelemetry-collector-contrib:0.112.0`** | `platform/observability/otel-collector.yaml` | **CONTRIB** distribution — the core image lacks the `tail_sampling` processor |
| **Chaos Mesh** | **2.8.3** | installed on AKS (not yet in Git) | ⚠️ *pin in Git*; on Git-Bash/Windows needs `MSYS_NO_PATHCONV=1` for the socket path |
| **Traefik** | **v3** (API group `traefik.io`, `v1alpha1`) | `platform/traefik/values.yaml` (chart version ⚠️ *confirm*) | weighted `TraefikService` = the canary data plane |
| **cert-manager** | ⚠️ *confirm on cluster* | `platform/cert-manager/*` (issuers only) | Let's Encrypt (staging→prod), ACME HTTP-01 |
| **Argo CD** | ⚠️ *confirm on cluster* | — | GitOps reconciler; app `targetRevision: main` |
| **kube-prometheus-stack** | ⚠️ *confirm on cluster* | `platform/observability/kube-prometheus-values.yaml` (values only) | Prometheus + Grafana + Alertmanager; `exemplar-storage` enabled via values |
| **Grafana Tempo** | ⚠️ *confirm on cluster* | `platform/observability/tempo-values.yaml` (values only) | HTTP port **3200**; trace backend |
| **Sealed Secrets** | ⚠️ *confirm on cluster* | `platform/sealed-secrets/*` | secrets in Git only as SealedSecrets |
| **Keycloak** (operator + CR) | ⚠️ *confirm on cluster* | `platform/argocd/keycloak-operator-application.yaml`, `templates/keycloak*.yaml` | realm `eurotransit`, public SPA client |

## 3. Cloud / cluster substrate

| Item | Value | Notes |
|---|---|---|
| Cloud | Azure **AKS** | RG `lab02_g03_group`, cluster `lab_g03_cluster` |
| Node pool | **3× Standard_B2s_v2** | 6 vCPU / 12 data-disk slots total = the capacity ceiling (see README §6): drives inventory-db 3→2, the Kafka brokers staying co-located, and the PriorityClass/right-sizing tuning |
| Subscription | Azure for **Students** (no Pay-As-You-Go) | the 12-disk ceiling is a direct consequence |
| Container registry | `labg03clusterregistry.azurecr.io` | the chart pulls every image from here; CI pushes here |

## 4. Frontend (storefront SPA — merged on `main`)

`capstone-application-g03/frontend` — the EuroTransit storefront (Vite + React + TypeScript, Tailwind, Redux
Toolkit + RTK Query, Axios, `keycloak-js`, SSE order-status stream). Pinned in `frontend/package.json`:

| Component | Version | Component | Version |
|---|---|---|---|
| React / React-DOM | **^18.3.1** | Vite | **^5.4.11** |
| TypeScript | **^5.6.3** | `@vitejs/plugin-react` | **^4.3.4** |
| Redux Toolkit | **^2.5.0** | React-Redux | **^9.2.0** |
| React Router DOM | **^6.28.0** | Axios | **^1.7.9** |
| `keycloak-js` | **^26.0.0** | Tailwind CSS | **^3.4.17** |
| Vitest | **^2.1.8** | MSW (test) | **^2.7.0** |
| Testing Library (react) | **^16.1.0** | `@types/node` / `@types/react` | **^20.17.6** / **^18.3.12** |

Built + pushed by the app-repo CI (`build-frontend`, bakes `VITE_KEYCLOAK_URL`); the config chart deploys it
(`frontend.enabled`). Kind image via the config repo's `just images-kind`.

## 5. Why these versions cohere (compatibility rationale)

- **Spring Boot 4 modularization is the through-line.** Boot 4 split several auto-configurations out of the
  actuator into dedicated starters — three explicit deps that Boot 3 gave for free and that fail **silently** if
  missing: `spring-boot-micrometer-tracing-opentelemetry` (no it → no `Tracer`/OTLP exporter, spans never
  exported), `spring-boot-starter-kafka` (builds the `KafkaTemplate` bean), `spring-boot-starter-flyway`
  (auto-migrates on startup). It also renamed the OTLP endpoint property to
  `management.opentelemetry.tracing.export.otlp.endpoint`.
- **Resilience4j matches the Boot line.** Both orders and payments use the `-spring-boot4` starter (2.4.0),
  required for annotation weaving on Boot 4 (+ `spring-boot-starter-aspectj`).
- **Kotlin 2.2 + `plugin.jpa`/`allOpen`** opens `@Entity`/`@Component` classes for Hibernate/Spring proxying.
- **Strimzi 1.x ⇒ KRaft-only.** Kafka 4.x under Strimzi 1.1.0 has no ZooKeeper; the cluster is a
  `KafkaNodePool` + `Kafka` CR, no legacy annotations.
- **CNPG ≥ 1.25** is the floor for `postgresql.synchronous` — the RPO=0 guarantee on inventory/orders depends
  on it; 1.29.1 is pinned.
- **Debezium 3.0 image derives FROM the matching Strimzi Kafka image** (`1.1.0-kafka-4.3.0`) so the Connect
  entrypoint + metrics agent line up with the operator managing it.
- **PG16 (not PG17)** is a deliberate trade: no native logical-slot failover, accepted because only best-effort
  notifications are exposed in the failover gap.
- **Argo Rollouts ≥ app v1.7** is the floor for the `traefik.io` API flags; the Traefik provider must be v3.

## 6. Known version gaps / follow-ups

- ⚠️ **Pin the unpinned platform components in Git** (Chaos Mesh 2.8.3, cert-manager, Argo CD,
  kube-prometheus-stack, Tempo, Sealed Secrets, Keycloak, Traefik chart) — the platform rule is "never
  `latest`", and several are currently installed by hand without a Git-recorded version.
