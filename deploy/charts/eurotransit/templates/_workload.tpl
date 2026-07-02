{{- /*
Reusable workload = 1 Deployment + 1 Service for ONE "track" of a service.

Args (dict):
  root     = $ (chart root context — inside a define, $ is the dict, so we pass the real root explicitly)
  name     = metadata name AND the app.kubernetes.io/name selector value (e.g. "orders" or "orders-canary")
  svc      = the service config object (from .Values.services.<x>)
  tag      = image tag to run (stable: svc.image.tag ; canary: the canary build's tag)
  replicas = (optional) explicit replica count; if unset, the HPA-omit logic on svc applies

Used by:
  - deployments.yaml  -> stable track  (name = <svc>,        tag = svc.image.tag)
  - canary.yaml       -> canary track  (name = <svc>-canary, tag = svc.canary.tag, fixed replicas)

WHY one template for both: stable and canary then can NEVER drift (same env/probes/resources). And because
`name` drives the app.kubernetes.io/name selector, the two tracks get DISTINCT, non-overlapping Services
(`orders` vs `orders-canary`) — so a weighted TraefikService can split traffic between them, and we never
touch the stable Deployment's (immutable) selector.
*/ -}}
{{- define "eurotransit.serviceWorkload" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  labels:
    {{- include "eurotransit.labels" (dict "svc" .name "root" .root) | nindent 4 }}
spec:
  {{- /* explicit replicas (canary) wins; else omit when the HPA owns scaling (Argo vs HPA fight). */}}
  {{- if .replicas }}
  replicas: {{ .replicas }}
  {{- else if not (dig "hpa" "enabled" false .svc) }}
  replicas: {{ .svc.replicaCount }}
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
            # OTLP traces -> the otel-collector gateway (root context via .root)
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
            {{- if dig "paypal" "enabled" false .svc }}
            {{- /* Payments -> PayPal (sandbox) server-to-server PSP. provider flips the app off the mock; base-url
                   is non-secret; the client-id/secret + sandbox test card come from the `paypal-api` secret
                   (a committed SealedSecret in prod, or the paypal.devSecrets-gated plaintext on kind). */}}
            - name: PAYMENTS_PROVIDER
              value: "paypal"
            - name: PAYPAL_BASE_URL
              value: {{ .svc.paypal.baseUrl | quote }}
            - name: PAYPAL_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.paypal.secretName }}
                  key: client-id
            - name: PAYPAL_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.paypal.secretName }}
                  key: client-secret
            - name: PAYPAL_TEST_CARD_NUMBER
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.paypal.secretName }}
                  key: test-card-number
            - name: PAYPAL_TEST_CARD_EXPIRY
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.paypal.secretName }}
                  key: test-card-expiry
            - name: PAYPAL_TEST_CARD_CVV
              valueFrom:
                secretKeyRef:
                  name: {{ .svc.paypal.secretName }}
                  key: test-card-cvv
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
