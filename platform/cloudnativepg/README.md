# CloudNativePG (operator) — platform component

The CloudNativePG **operator** is installed once per cluster (namespace `cnpg-system`),
following the platform bootstrap. The per-service databases are **not** declared here — they live as `Cluster`
CRs in the application chart (`deploy/charts/eurotransit/templates/databases.yaml`), so that
database ownership stays with each service's desired state.

Install (bootstrap, once):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace
```
