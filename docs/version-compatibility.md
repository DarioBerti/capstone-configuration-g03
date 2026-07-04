# EuroTransit — Version & compatibility matrix

> Single reference for the versions the system is built and run against, and **why they cohere**. Two kinds
> of pin live here: (a) versions **hard-coded in the repos** (build files, image tags, Argo `targetRevision`),
> which are authoritative — and (b) components installed once on the cluster whose version is **not yet pinned
> in Git** (marked ⚠️ *confirm on cluster*), which is a reproducibility gap worth closing (the platform rule is
> "never `latest`", see `platform/README.md`). Update this file whenever a build file or an image tag changes.
>
> Sources: app `services/*/build.gradle.kts` + `gradle/wrapper`, config `platform/*`, `deploy/charts/eurotransit`.
> Companion: `docs/design.md` (config), `../capstone-application-g03/docs/DESIGN.md` (app).

## 1. Language, build & runtime toolchain (application repo)

| Component | Version | Pinned in | Notes |
|---|---|---|---|
| Kotlin (JVM, `plugin.spring`, `plugin.jpa`) | **2.2.21** | each `build.gradle.kts` | one wrapper per service; `-Xjsr305=strict`, `-Xannotation-default-target=param-property` |
| Spring Boot | **4.0.3** | each `build.gradle.kts` | Boot 4 is modularized — tracing/kafka/flyway auto-config moved out of actuator into dedicated starters (see §5) |
| Spring dependency-management plugin | **1.1.7** | each `build.gradle.kts` | imports the Boot BOM → most deps are version-less & mutually compatible |
| JDK toolchain | **21** (`JavaLanguageVersion.of(21)`) | each `build.gradle.kts` | Gradle auto-provisions if absent |
| Gradle (wrapper) | **9.3.1** | `gradle/wrapper/gradle-wrapper.properties` | per-service wrapper, no root build |
| Jackson | **3.x** (`tools.jackson`) | Boot BOM | Boot 4 moved to Jackson 3 (`tools.jackson`, not `com.fasterxml`) |
| Hibernate / Spring Data JPA | Boot BOM | Boot BOM | `ddl-auto: validate` only; Flyway owns the schema |
| Flyway | Boot BOM (`spring-boot-starter-flyway` + `flyway-database-postgresql`) | Boot BOM | Boot 4 needs the *starter* (module `spring-boot-flyway`) to auto-migrate — bare `flyway-core` does not |
| PostgreSQL JDBC driver | Boot BOM (`org.postgresql:postgresql`) | Boot BOM | — |
| Testcontainers (postgresql, junit-jupiter) | Boot BOM | Boot BOM | real Postgres in tests, no H2 |

### Resilience4j (⚠️ intentional inconsistency, tracked)

| Service | Artifact | Version | Why |
|---|---|---|---|
| **orders** | `resilience4j-spring-boot4` (+ `-kotlin`, `-micrometer`) | **2.4.0** | 2.4.0 shipped the dedicated Boot-4 starter; sole use left = `@RateLimiter` intake shed (needs `spring-boot-starter-aspectj`) |
| **payments** | `resilience4j-spring-boot3` (+ `-kotlin`, `-micrometer`) | **2.3.0** | programmatic-only today, so the Boot-3 starter still works; **optional consistency bump to `-spring-boot4` 2.4.0** (agent-log #2). Becomes relevant once the breaker is re-placed around the real PSP egress |

## 2. Platform operators & infrastructure (configuration repo)

| Component | Version | Pinned in | Notes |
|---|---|---|---|
| **Strimzi** (Kafka operator) | **1.1.0** | `platform/strimzi/kafka.yaml`, `platform/debezium/Dockerfile` | 1.x = **KRaft-only via KafkaNodePool** (no ZooKeeper, no `kraft`/`node-pools` annotations). README still cites 1.0.0 (06-28) → bumped to 1.1.0 on AKS 03/07 |
| **Apache Kafka** (broker) | **4.3.0** | `platform/strimzi/kafka.yaml` (`spec.kafka.version`) | API `kafka.strimzi.io/v1` |
| **CloudNativePG** (operator) | **1.29.1** | `platform/README.md` | **≥1.25 required** for `postgresql.synchronous` (inventory/orders RPO=0) |
| **PostgreSQL** (managed by CNPG) | **16** | CNPG `Cluster` CRs (`templates/databases.yaml`) | **DECISION: stay on PG16, no PG17 failover-slots** — the logical slot dies with the primary; the sweeper self-heals the money path, only best-effort notifications can be lost (design §4-B, chaos #5) |
| **Debezium** (Postgres connector) | **3.0.0.Final** | `platform/debezium/Dockerfile` (`DEBEZIUM_VERSION`) | log-based CDC drains the outbox off the WAL; connector image = `debezium-connect:1.0.0` built **FROM `quay.io/strimzi/kafka:1.1.0-kafka-4.3.0`** so the Strimzi Connect entrypoint + metrics agent are present |
| Debezium Connect image (ours) | **`eurotransit/debezium-connect:1.0.0`** | `platform/debezium/Dockerfile`, built by CI on demand | 3 replicas (HA); connectors declared as `KafkaConnector` CRs |
| **Argo Rollouts** | chart **2.41.0** = app **v1.9.0** | `platform/argocd/argo-rollouts-application.yaml` | **≥ app v1.7 required** for the `--traefik-api-group=traefik.io`/`--traefik-api-version=traefik.io/v1alpha1` flags |
| **OTel Collector** (gateway) | **`otel/opentelemetry-collector-contrib:0.112.0`** | `platform/observability/otel-collector.yaml` | **CONTRIB** distribution — the core image lacks the `tail_sampling` processor |
| **Chaos Mesh** | **2.8.3** | installed on AKS 03/07 (not yet in Git) | ⚠️ *pin in Git*; on Git-Bash/Windows needs `MSYS_NO_PATHCONV=1` for the socket path (agent-log #25) |
| **Traefik** | **v3** (API group `traefik.io`, `v1alpha1`) | `platform/traefik/values.yaml` (chart version ⚠️ *confirm*) | weighted `TraefikService` = the canary data plane |
| **cert-manager** | ⚠️ *confirm on cluster* | `platform/cert-manager/*` (issuers only) | Let's Encrypt (staging→prod), ACME HTTP-01 |
| **Argo CD** | ⚠️ *confirm on cluster* | — | GitOps reconciler; app `targetRevision: main` |
| **kube-prometheus-stack** | ⚠️ *confirm on cluster* | `platform/observability/kube-prometheus-values.yaml` (values only) | Prometheus + Grafana + Alertmanager; `--enable-feature=exemplar-storage` set via values (agent-log #25) |
| **Grafana Tempo** | ⚠️ *confirm on cluster* | `platform/observability/tempo-values.yaml` (values only) | HTTP port **3200** (not 3100 — agent-log #25); trace backend |
| **Sealed Secrets** | ⚠️ *confirm on cluster* | `platform/sealed-secrets/*` | secrets in Git only as SealedSecrets |
| **Keycloak** (operator + CR) | ⚠️ *confirm on cluster* | `platform/argocd/keycloak-operator-application.yaml`, `templates/keycloak*.yaml` | realm `eurotransit`, client `eurotransit-frontend` (public SPA) |
| **k6** (load) | ⚠️ *confirm* | `platform/k6/*` | dev-only load generation |

## 3. Cloud / cluster substrate

| Item | Value | Notes |
|---|---|---|
| Cloud | Azure **AKS** | RG `lab02_g03_group`, cluster `lab_g03_cluster` |
| Node pool | **3× Standard_B2s_v2** | 6 vCPU / 12 data-disk slots total = the capacity ceiling behind the Part-2 decision (inventory-db 3→2) |
| Subscription | Azure for **Students** (no Pay-As-You-Go) | the 12-disk ceiling is a direct consequence |
| Container registry | `labg03clusterregistry.azurecr.io` | the chart pulls every image from here; CI pushes here (agent-log #14) |

## 4. Frontend (⚠️ on branch `async-rework`, not yet merged to `main`)

The SPA (`capstone-application-g03/frontend`) is being reworked by Riccardo (Vite + React + `keycloak-js`,
SSE order-status stream). **Versions to be filled from `frontend/package.json` once `async-rework` merges** —
do not treat as final until then.

## 5. Why these versions cohere (compatibility rationale)

- **Spring Boot 4 modularization is the through-line.** Boot 4 split several auto-configurations out of the
  actuator into dedicated starters. This forces three explicit deps that Boot 3 gave for free and that,
  if missing, fail **silently**: `spring-boot-micrometer-tracing-opentelemetry` (no it → no `Tracer`/OTLP
  exporter, spans never exported — app agent-log 02/07 & config #23), `spring-boot-starter-kafka` (builds the
  `KafkaTemplate` bean), `spring-boot-starter-flyway` (auto-migrates on startup). It also renamed the OTLP
  endpoint property to `management.opentelemetry.tracing.export.otlp.endpoint` (config #23).
- **Resilience4j must match the Boot line.** The `-spring-boot4` starter (2.4.0) is required for annotation
  weaving on Boot 4; `-spring-boot3` (2.3.0) only works because payments uses it programmatically (agent-log #2).
- **Kotlin 2.2 + `plugin.jpa`/`allOpen`** opens `@Entity`/`@Component` classes for Hibernate/Spring proxying.
- **Strimzi 1.x ⇒ KRaft-only.** Kafka 4.x under Strimzi 1.1.0 has no ZooKeeper; the cluster is a
  `KafkaNodePool` + `Kafka` CR, no legacy annotations.
- **CNPG ≥ 1.25** is the floor for `postgresql.synchronous` — the RPO=0 guarantee on inventory/orders
  depends on it; 1.29.1 is the pinned version.
- **Debezium 3.0 image must derive FROM the matching Strimzi Kafka image** (`1.1.0-kafka-4.3.0`) so the
  Connect entrypoint + metrics agent line up with the operator managing it.
- **PG16 (not PG17)** is a deliberate trade: no native logical-slot failover, accepted because only
  best-effort notifications are exposed in the failover gap (design §4-B).
- **Argo Rollouts ≥ app v1.7** is the floor for the `traefik.io` API flags; the Traefik provider must be v3.

## 6. Known version gaps / follow-ups

- ⚠️ **Pin the unpinned platform components in Git** (Chaos Mesh 2.8.3, cert-manager, Argo CD, kube-prometheus-stack,
  Tempo, Sealed Secrets, Keycloak, Traefik chart) — the platform rule is "never `latest`", and several are currently
  installed by hand without a Git-recorded version.
- ⚠️ **payments Resilience4j 2.3.0 → 2.4.0 `-spring-boot4`** consistency bump (relevant once the breaker is
  re-placed around the real PSP egress — PayPal, on `async-rework`).
- ⚠️ **Frontend versions** to be captured on merge of `async-rework`.
