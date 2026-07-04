# Sealed Secrets — platform component

The Sealed Secrets controller (Bitnami) decrypts committed `SealedSecret`s into in-cluster `Secret`s.
Secrets live in Git **only** as `SealedSecret`s; plaintext `Secret` manifests are never committed
(enforced by `.gitignore` + PR policy).

## One canonical controller

There must be exactly **one** controller — one keypair. It is declared in Git as an Argo CD Application:
[`../argocd/sealed-secrets-application.yaml`](../argocd/sealed-secrets-application.yaml)
(chart `2.18.6` / app `v0.37.0`, namespace `sealed-secrets`, sync-wave `-10`).

> History: the cluster carried **two** controllers (a `sealed-secrets`-ns v0.31.0 and a `kube-system`
> v0.37.0 = two keypairs) — which is exactly why the only SealedSecret failed to decrypt. Consolidation
> standardises on the `sealed-secrets`-namespace controller (now v0.37.0) and removes the `kube-system` one.

### Back up the key (and keep it OUT of Git)

The controller's private key decrypts every SealedSecret; if it is lost, a fresh controller generates a new
key and all SealedSecrets become undecryptable. Back it up right after install:

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup   # store securely, NOT in Git
```

## The sealed inventory (class-C secrets)

CNPG-generated DB creds (`<db>-app`, `-ca`, `-server`, `-replication`) and cert-manager TLS are created
in-cluster and are **not** sealed — they never enter Git. What IS sealed lives in [`../secrets/`](../secrets/):

| SealedSecret | ns | consumed by |
|---|---|---|
| `keycloak-db` | eurotransit | CNPG managed role on catalog-db + Keycloak DB login |
| `keycloak-bootstrap-admin` | eurotransit | Keycloak CR bootstrap admin |
| `orders-db-debezium` / `inventory-db-debezium` / `payments-db-debezium` | eurotransit | CNPG `debezium` managed-role password |
| `debezium-db` | kafka | Connect cluster connector auth — **must match** the `*-db-debezium` passwords |
| `paypal-api` | eurotransit | payments PSP (only once PayPal / `async-rework` is live) |

## Regenerating / rotating

Seal against the canonical controller with [`../secrets/seal.sh`](../secrets/seal.sh) (pipes live values
straight into kubeseal — plaintext never touches disk or Git):

```bash
SRC_CTX=cpo_cluster       SEAL_CTX=cpo_cluster       ./platform/secrets/seal.sh   # AKS
SRC_CTX=kind-eurotransit  SEAL_CTX=kind-eurotransit  ./platform/secrets/seal.sh   # kind rehearsal
```

Manual one-off (example):

```bash
kubectl create secret generic eurotransit-runtime --from-literal=SOME_TOKEN=... \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
      --format yaml --scope strict > eurotransit-runtime-sealedsecret.yaml
```

## Cutover — adopting the current hand-created Secrets

The controller will **not** overwrite a `Secret` it doesn't own. For each secret currently created by hand,
delete the plaintext `Secret` so the applied `SealedSecret` recreates it owned by the controller — a brief
per-secret window (CNPG / Keycloak re-read on reconcile). **Rehearse on kind first**; on AKS do it at low
traffic. Verify: `kubectl get sealedsecret -A` all `SYNCED=True`, and the recreated Secrets now show
`ownerReferences:` a `SealedSecret`.
