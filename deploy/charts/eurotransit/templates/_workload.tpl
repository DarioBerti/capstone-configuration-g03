{{- /*
Reusable workload = 1 Deployment OR 1 Argo Rollout + 1 Service for a service.

Args (dict):
  root     = $ (chart root context — inside a define, $ is the dict, so we pass the real root explicitly)
  name     = metadata name AND the app.kubernetes.io/name selector value (e.g. "orders")
  svc      = the service config object (from .Values.services.<x>)
  tag      = image tag to run (bumped by CI to the commit SHA)
  replicas = (optional) explicit replica count; if unset, the HPA-omit logic on svc applies
  rollout  = (optional) the svc's `rollout` block. When it carries a strategy ("canary" | "bluegreen") the
             workload renders as an Argo Rollouts `Rollout` CRD with that strategy instead of a Deployment —
             SAME pod template, so a progressively-delivered service can never drift from a plain one.

Used by deployments.yaml for every entry in .Values.services.

Progressive delivery (Fase 5): the Rollouts controller manages the ReplicaSets itself (no hand-rolled
canary/green Deployments): `canary` shifts /api/<svc> traffic through the weighted TraefikService
`<name>-weighted` (see progressive-delivery.yaml) gated by the background AnalysisRun (analysis.yaml);
`bluegreen` flips the stable Service's selector to the preview ReplicaSet on promotion. The controller
patches the Service selectors / TraefikService weights at runtime — the Argo CD app ignores those
controller-managed fields (see platform/argocd/eurotransit-application.yaml ignoreDifferences).
*/ -}}
{{- define "eurotransit.serviceWorkload" -}}
{{- $rollout := .rollout | default dict }}
{{- $strategy := dig "strategy" "" $rollout }}
{{- if $strategy }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
{{- else }}
apiVersion: apps/v1
kind: Deployment
{{- end }}
metadata:
  name: {{ .name }}
  labels:
    {{- include "eurotransit.labels" (dict "svc" .name "root" .root) | nindent 4 }}
spec:
  {{- /* explicit replicas wins; else omit when the HPA owns scaling (Argo vs HPA fight — the HPA's
         scaleTargetRef follows the workload kind, see hpa.yaml). */}}
  {{- if .replicas }}
  replicas: {{ .replicas }}
  {{- else if not (dig "hpa" "enabled" false .svc) }}
  replicas: {{ .svc.replicaCount }}
  {{- end }}
  {{- if eq $strategy "canary" }}
  strategy:
    canary:
      # the two Services traffic is split between; Rollouts pins each to its ReplicaSet by injecting the
      # rollouts-pod-template-hash into their selectors (both are declared with the plain stable selector)
      stableService: {{ .name }}
      canaryService: {{ .name }}-canary
      trafficRouting:
        traefik:
          # the weighted TraefikService (progressive-delivery.yaml) whose weights the controller drives
          weightedTraefikServiceName: {{ .name }}-weighted
      {{- if dig "canary" "analysis" "enabled" false $rollout }}
      # background analysis: runs from the first weight step onward; a failure AUTO-ABORTS the rollout
      # (traffic back to stable). Templates in analysis.yaml (canary-scoped SLO + consumer failures).
      analysis:
        templates:
          - templateName: {{ .name }}-canary-slo
        startingStep: 1
      {{- end }}
      steps:
        {{- range dig "canary" "steps" (list) $rollout }}
        {{- if .canaryReplicas }}
        # pin the canary ReplicaSet size (bounds the Kafka consumer-side exposure of the canary code)
        - setCanaryScale:
            replicas: {{ .canaryReplicas }}
        {{- end }}
        {{- if .matchTrafficWeight }}
        # release the pin: from here the canary scales with its traffic share
        - setCanaryScale:
            matchTrafficWeight: true
        {{- end }}
        - setWeight: {{ .weight }}
        {{- if .pause }}
        - pause:
            duration: {{ .pause }}
        {{- end }}
        {{- end }}
  {{- else if eq $strategy "bluegreen" }}
  strategy:
    blueGreen:
      # promotion = the controller atomically re-points the ACTIVE Service's selector to the preview
      # ReplicaSet; the preview Service lets the candidate be smoke-tested in-cluster before the flip
      activeService: {{ .name }}
      previewService: {{ .name }}-preview
      autoPromotionEnabled: {{ dig "bluegreen" "autoPromotionEnabled" false $rollout }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "eurotransit.selectorLabels" (dict "svc" .name) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "eurotransit.labels" (dict "svc" .name "root" .root) | nindent 8 }}
    spec:
      # SIGTERM drain window (Pillar A): readiness refuses traffic, in-flight work finishes within this budget
      terminationGracePeriodSeconds: 30
      {{- if .svc.criticalPath }}
      # Spread critical-path pods across nodes so a single node loss can't take the service fully down
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "eurotransit.selectorLabels" (dict "svc" .name) | nindent 14 }}
      {{- end }}
      containers:
        - name: {{ .name }}
          # immutable tag (commit SHA) — bumped by CI for stable, set to the canary build for the canary track
          image: "{{ .svc.image.repository }}:{{ .tag }}"
          imagePullPolicy: {{ .svc.image.pullPolicy }}
          # pre-stop pause: endpoint controllers drop the Pod from the Service before SIGTERM (no request races in)
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]
          ports:
            - name: http
              containerPort: {{ .svc.port }}
              protocol: TCP
          env:
            # Pod identity -> ECS log field service.node.name (which replica produced a line)
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: LOGGING_STRUCTURED_ECS_SERVICE_NODE_NAME
              value: $(POD_NAME)
            # Console log format. `ecs` emits structured ECS JSON for a log pipeline to parse (prod,
            # global.logFormat=ecs); on kind global.logFormat="" so the console stays human-readable
            # plaintext — kind runs no log aggregation stack, so the JSON would be write-only. This env
            # outranks the `logging.structured.format.console: ecs` in the app's application-cluster.yml.
            - name: LOGGING_STRUCTURED_FORMAT_CONSOLE
              value: {{ .root.Values.global.logFormat | quote }}
            # in-cluster Spring profile (quiet SQL, hidden health details)
            - name: SPRING_PROFILES_ACTIVE
              value: "cluster"
            # OTLP traces -> the otel-collector gateway (root context via .root).
            # Boot 4 moved the property to management.opentelemetry.tracing.export.otlp.endpoint — without
            # it bound, OtlpTracingAutoConfiguration creates NO exporter: spans exist in-process (traceId in
            # the logs) but nothing is ever sent (found live on AKS 02/07, agent-log #23). The old Boot-3
            # name is kept alongside until the app's application.yml drops its stale key.
            - name: MANAGEMENT_OPENTELEMETRY_TRACING_EXPORT_OTLP_ENDPOINT
              value: {{ .root.Values.global.otlpEndpoint | quote }}
            - name: MANAGEMENT_OTLP_TRACING_ENDPOINT
              value: {{ .root.Values.global.otlpEndpoint | quote }}
            {{- if .svc.usesKafka }}
            - name: KAFKA_BOOTSTRAP
              value: {{ .root.Values.global.kafkaBootstrap | quote }}
            {{- end }}
            {{- /* service-specific env (e.g. Orders' sibling base URLs) */}}
            {{- range $envName, $envValue := (dig "extraEnv" (dict) .svc) }}
            - name: {{ $envName }}
              value: {{ $envValue | quote }}
            {{- end }}
            {{- if .svc.secured }}
            {{- /* OAuth2 resource server: validate Keycloak JWTs */}}
            - name: KEYCLOAK_JWK_SET_URI
              value: {{ .root.Values.global.oidc.jwkSetUri | quote }}
            - name: KEYCLOAK_ISSUER
              value: {{ .root.Values.global.oidc.issuer | quote }}
            {{- end }}
            {{- if .svc.oidcClient }}
            {{- /* client-credentials so this service can mint a SERVICE token for outbound calls */}}
            - name: KEYCLOAK_TOKEN_URI
              value: {{ .root.Values.global.oidc.tokenUri | quote }}
            - name: ORDERS_CLIENT_ID
              value: {{ .svc.oidcClient.clientId | quote }}
            - name: ORDERS_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.oidcClient.secretName }}
                  key: client-secret
            {{- end }}
            {{- if .svc.db }}
            {{- /* DB_* from the <db>-app Secret CNPG generates (creds never in Git). Canary shares the SAME db. */}}
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.db }}-app
                  key: host
            - name: DB_PORT
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.db }}-app
                  key: port
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.db }}-app
                  key: dbname
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.db }}-app
                  key: username
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.db }}-app
                  key: password
            {{- end }}
          # readiness = "serve traffic now?" (removes pod from Service endpoints on fail, no restart)
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 10
            failureThreshold: 3
          # liveness = "process wedged?" (restarts pod) -> checks only the app itself, never a downstream
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 15
            failureThreshold: 3
          # startup = slow-boot grace (up to 24*5s = 2 min) before liveness counts
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 24
          resources:
            {{- toYaml .root.Values.resources | nindent 12 }}
---
# stable in-cluster address: other pods reach it as http://<name>:<port>
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels:
    {{- include "eurotransit.labels" (dict "svc" .name "root" .root) | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "eurotransit.selectorLabels" (dict "svc" .name) | nindent 4 }}
  ports:
    - name: http
      port: {{ .svc.port }}
      targetPort: http
      protocol: TCP
{{- end -}}
