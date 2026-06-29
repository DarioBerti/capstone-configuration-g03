# Local image registry for kind (dev only)

Mirrors how the real cluster pulls from ACR, but locally. A `registry:2` container
(`kind-registry`) listens on `localhost:5001`; the kind nodes' containerd is told to resolve
`localhost:5001` to it, so you `docker push` locally exactly like you'll push to ACR later.

How the pieces fit:

- `bootstrap/kind-config.yaml` — `containerdConfigPatches` enables containerd's registry config
  dir (`config_path = /etc/containerd/certs.d`). Baked in so a fresh `kind create` has the hook.
- `just registry-up` — starts the `kind-registry` container, writes each node's
  `certs.d/localhost:5001/hosts.toml` (→ `http://kind-registry:5000`), connects the registry to
  the `kind` docker network, and applies `local-registry-hosting.yaml`.
- `just images-kind` — builds the 5 services (native arch) and `docker push`es them to
  `localhost:5001/eurotransit/<svc>:dev`.
- `deploy/charts/eurotransit/values-kind.yaml` — points each service image at that registry.

The real cluster instead pulls from `labg03clusterregistry.azurecr.io` (base `values.yaml`) — unchanged.

Recreate everything from scratch with: `just cluster-down && just bootstrap-kind`.