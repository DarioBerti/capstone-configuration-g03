#!/usr/bin/env bash
# Regenerate the committed SealedSecrets for the class-C app secrets by sealing the CURRENT live values
# against the canonical Sealed Secrets controller. Writes platform/secrets/*-sealedsecret.yaml.
# Plaintext is piped straight into kubeseal — it never lands on disk or in Git.
#
# Prereqs: kubeseal + kubectl + jq; the canonical controller running (Application: sealed-secrets, ns
# sealed-secrets); read access to the SOURCE cluster that holds the current plaintext values.
#
# Usage:
#   SRC_CTX=cpo_cluster        SEAL_CTX=cpo_cluster        ./platform/secrets/seal.sh   # AKS
#   SRC_CTX=kind-eurotransit   SEAL_CTX=kind-eurotransit   ./platform/secrets/seal.sh   # kind rehearsal
#     SRC_CTX  = context to READ current secret values from   (default: current context)
#     SEAL_CTX = context whose controller cert to seal AGAINST (default: SRC_CTX)
set -euo pipefail

SRC_CTX="${SRC_CTX:-$(kubectl config current-context)}"
SEAL_CTX="${SEAL_CTX:-$SRC_CTX}"
CTRL_NS="${CTRL_NS:-sealed-secrets}"
CTRL_NAME="${CTRL_NAME:-sealed-secrets}"
# OUT defaults to this dir (the committed location); override to a scratch dir for a kind rehearsal so
# kind-derived blobs don't overwrite the real AKS-sealed manifests, e.g. OUT=/tmp/seal-rehearsal
OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)}"

echo ">> sealing against $CTRL_NAME/$CTRL_NS on [$SEAL_CTX]; reading current values from [$SRC_CTX]"
CERT="$(mktemp)"; trap 'rm -f "$CERT"' EXIT
kubeseal --context "$SEAL_CTX" --controller-namespace "$CTRL_NS" --controller-name "$CTRL_NAME" --fetch-cert > "$CERT"

# reseal <namespace> <secret-name>: read the live Secret, strip runtime metadata, seal (strict scope =
# bound to name+namespace), write the manifest. kubeseal input needs only name/namespace/data.
reseal() {
  local ns="$1" name="$2"
  echo "   - $ns/$name"
  kubectl --context "$SRC_CTX" -n "$ns" get secret "$name" -o json \
    | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields,.metadata.ownerReferences,.status,.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
    | kubeseal --cert "$CERT" --format yaml --scope strict \
    > "$OUT/${name}-sealedsecret.yaml"
}

# eurotransit ns — class-C app + CNPG managed-role secrets
reseal eurotransit keycloak-db
reseal eurotransit keycloak-bootstrap-admin
reseal eurotransit orders-db-debezium
reseal eurotransit inventory-db-debezium
reseal eurotransit payments-db-debezium
# kafka ns — the Connect cluster authenticates with this; sealing the SAME live source guarantees the
# passwords match the *-db-debezium ones above (CNPG sets the role password from those).
reseal kafka debezium-db
# paypal-api is branch-only (async-rework) and not on the cluster yet — seal it once payments/PayPal is live:
#   reseal eurotransit paypal-api

echo ">> done -> platform/secrets/*-sealedsecret.yaml (encrypted; safe to commit). Review, then commit."
