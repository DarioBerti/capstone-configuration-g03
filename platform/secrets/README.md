# Committed SealedSecrets (class-C app secrets)

Encrypted-at-rest `SealedSecret` manifests — safe to commit. The Argo CD Application
[`../argocd/eurotransit-secrets-application.yaml`](../argocd/eurotransit-secrets-application.yaml)
reconciles the `*-sealedsecret.yaml` here (sync-wave `-3`); the controller
([`../argocd/sealed-secrets-application.yaml`](../argocd/sealed-secrets-application.yaml), wave `-10`)
unseals them into the `Secret`s that CNPG managed roles, Keycloak, the Kafka Connect cluster and
payments consume.

- **`*-sealedsecret.yaml`** — the committed, encrypted secrets (each carries its own `namespace:`).
- **`seal.sh`** — regenerate them by sealing the current live values against the canonical controller.

See [`../sealed-secrets/README.md`](../sealed-secrets/README.md) for the full inventory, the key-backup
step, and the cutover (adopting the current hand-created Secrets).

> Never commit a plaintext `*-secret.yaml` here — `.gitignore` blocks it. Only `*-sealedsecret.yaml`.
