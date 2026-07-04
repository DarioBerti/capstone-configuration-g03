# Sealed Secrets — platform component

The Sealed Secrets controller is installed once per cluster. Secrets live in Git
**only** as `SealedSecret`s; plaintext `Secret` manifests are never committed (enforced by
`.gitignore` and the PR policy checks).

Seal a secret (example):

```bash
kubectl create secret generic eurotransit-runtime \
  --from-literal=SOME_TOKEN=... --dry-run=client -o yaml \
  | kubeseal --format yaml > eurotransit-runtime-sealedsecret.yaml
```

CloudNativePG-generated DB credentials (`<db>-app`) are created in-cluster by the operator and
are **not** sealed here — they never enter Git.
