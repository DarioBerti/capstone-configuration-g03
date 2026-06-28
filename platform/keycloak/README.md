# Keycloak (OIDC identity) — deployment notes

EuroTransit uses **Keycloak** as its OIDC identity provider, run by the **Keycloak Operator**. App
services validate Keycloak JWTs as OAuth2 resource servers; the React frontend logs in via Keycloak
(Authorization Code + PKCE); the `users` service stores app-side profiles keyed by the Keycloak subject.

## Pieces

| Piece | Where | What |
|---|---|---|
| Operator (CRDs + controller) | `platform/keycloak/operator/` + `platform/argocd/keycloak-operator-application.yaml` | Installs the `Keycloak`/`KeycloakRealmImport` CRDs and the controller into the `eurotransit` namespace |
| Keycloak instance | `deploy/charts/eurotransit/templates/keycloak.yaml` | `Keycloak` CR; DB on the shared `catalog-db`, TLS at the Traefik ingress |
| Realm + clients | `deploy/charts/eurotransit/templates/keycloak-realm.yaml` | `eurotransit` realm, `eurotransit-frontend` (public SPA) + `orders-svc` (service) clients, `USER`/`ADMIN` roles, audience mapper |
| Login ingress | `deploy/charts/eurotransit/templates/keycloak-ingress.yaml` | `auth.<domain>` → `keycloak-service:8080` |
| Keycloak DB | `deploy/charts/eurotransit/templates/databases.yaml` (`catalog-db.managedRoles` + `extraDatabases`) | `keycloak` role + `keycloakdb` on the shared catalog Postgres |

## Install order (CRDs first)

The eurotransit chart contains `Keycloak`/`KeycloakRealmImport` resources whose CRDs come from the
operator, so the operator must reconcile first.

- **Argo CD**: the operator Application has `sync-wave: -5` (before the eurotransit app at wave 0); the
  Keycloak resources carry `SkipDryRunOnMissingResource=true` so the first sync tolerates missing CRDs
  and converges on retry.
- **Local kind**: `just keycloak-install` (applies the operator) runs before `just app-deploy`. See the
  config-repo `justfile` / `bootstrap-kind`.

## Secrets

Three secrets live in the `eurotransit` namespace:

| Secret | Keys | Used by |
|---|---|---|
| `keycloak-db` | `username`, `password` | CNPG-managed `keycloak` role **and** the Keycloak CR's DB connection |
| `keycloak-initial-admin` | `username`, `password` | Keycloak bootstrap admin (console login) |
| `orders-oidc` | `client-secret` | Orders reads it (`ORDERS_CLIENT_SECRET`); must equal the realm's `orders-svc` client secret |

- **Local kind**: rendered as plaintext by the chart when `keycloak.devSecrets=true` (set in
  `values-kind.yaml`). No kubeseal needed.
- **Production**: `keycloak.devSecrets` stays **false** (base `values.yaml`), so the chart renders no
  secrets. Commit the three secrets as **SealedSecrets** instead, e.g.:

  ```bash
  # keycloak DB role (also the Keycloak CR DB creds)
  kubectl create secret generic keycloak-db -n eurotransit \
    --type=kubernetes.io/basic-auth \
    --from-literal=username=keycloak --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml | kubeseal --format yaml > keycloak-db-sealedsecret.yaml

  # bootstrap admin
  kubectl create secret generic keycloak-initial-admin -n eurotransit \
    --from-literal=username=admin --from-literal=password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml | kubeseal --format yaml > keycloak-admin-sealedsecret.yaml

  # orders-svc client secret (MUST match the realm client secret — see below)
  kubectl create secret generic orders-oidc -n eurotransit \
    --from-literal=client-secret="$SECRET" \
    --dry-run=client -o yaml | kubeseal --format yaml > orders-oidc-sealedsecret.yaml
  ```

  Commit the sealed files under a path the eurotransit Argo app syncs (plaintext `secret*.yaml` is
  git-ignored — see `platform/sealed-secrets/README.md`).

### Keeping the orders-svc secret in sync

The realm import seeds the `orders-svc` client secret from `keycloak.dev.ordersClientSecret`. In prod,
override that value via a **private values overlay** (not committed) so it matches the `orders-oidc`
SealedSecret — or rotate the client secret in the Keycloak console and update the SealedSecret. Never
commit the real secret in `values.yaml`.

## Test accounts (dev/kind only)

A fresh kind cluster seeds two ready-to-use logins into the `eurotransit` realm (via
`keycloak.testUsers` in `values-kind.yaml`). They are **never** rendered in prod (`testUsers: []` in the
base `values.yaml`).

| Username | Password | Email | Realm roles |
|---|---|---|---|
| `alice` | `alice` | alice@eurotransit.test | `USER` |
| `bob` | `bob` | bob@eurotransit.test | `USER`, `ADMIN` |

Use them by signing in through the frontend (`http://localhost:5173` is an allowed redirect on kind).

For a token from the terminal, kind also enables the password grant on the `eurotransit-frontend`
client (`devDirectAccessGrants: true`):

```bash
# get an access token for alice
TOKEN=$(curl -s http://localhost:8180/realms/eurotransit/protocol/openid-connect/token \
  -d grant_type=password -d client_id=eurotransit-frontend \
  -d username=alice -d password=alice | jq -r .access_token)

# call a secured endpoint (JIT-provisions her profile on first hit)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8085/api/users/me | jq
```

(Adjust the Keycloak host/port to how you reach it locally — e.g. the `auth.localhost` ingress or a
`kubectl port-forward svc/keycloak-service 8180:8080 -n eurotransit`.)

Add or change accounts by editing `keycloak.testUsers` in `values-kind.yaml`. The realm import seeds
users on realm creation; to re-seed after changes, delete the `KeycloakRealmImport` (or the realm) and
let it re-import.

## OIDC URLs

- `global.oidc.issuer` must equal the `iss` claim Keycloak stamps on tokens — the public host
  (`https://auth.<domain>/realms/eurotransit`).
- Services use `jwk-set-uri` (lazy) for signature validation, so they boot even if Keycloak is briefly
  down (Pillar C). On kind, `values-kind.yaml` points `jwkSetUri`/`tokenUri` at the in-cluster Service to
  avoid an ingress/TLS hairpin on a laptop.
