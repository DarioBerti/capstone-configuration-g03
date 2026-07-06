# Agent threat model — the coding agent as a non-human actor

> Required by the capstone: reason about the blast radius of a coding agent inside our delivery loop.

## Where the agent sits

A coding agent can write code and manifests and open pull requests against **both** repos. The configuration
repo is reconciled by Argo CD, so anything merged there reaches the cluster within one sync interval. That puts
the agent **inside the control loop**: a bad *merged* change is a bad *deployment*.

## What the agent can and cannot do (least privilege)

| The agent has | The agent does NOT have |
|---|---|
| the ability to propose branches / PRs (Git only) | any cluster credentials or kubeconfig |
| read access to both repos | registry push creds (`ACR_*`) or the `CONFIG_REPO_PAT` |
| — | write access to `main` (branch protection blocks direct pushes) |

Same principle as CI: the agent influences the cluster **only** through Git, and only after a gate we control.
The push credentials and the PAT live solely in GitHub Actions secrets, used *after* a human-reviewed merge.

## The gates before any agent change ships

1. **Human review** — branch protection on `main` in both repos; no PR merges without it.
2. **Policy-as-code in CI** (config repo) — `helm lint` + `kubeconform`/OPA reject privileged pods, `:latest` on
   the critical path, missing probes/PDBs, or plaintext Secrets (only SealedSecrets allowed). These run on the
   PR, before merge.

## Worst case, and why it's contained

**Worst case:** a subtly wrong change slips through — e.g. a liveness probe that checks a downstream, an
over-permissive ServiceAccount, a non-idempotent handler, or dropping `min.insync.replicas` — and degrades the
critical path after merge.

**Why it's contained:**
- review + policy checks catch the common classes *before* merge;
- Argo CD history + `git revert` give a fast rollback;
- PDBs, topology spread, and HPA limit the blast radius;
- SLO burn-rate alerts surface user-visible impact quickly.

The agent never has a direct write path to the cluster, so the *only* way its change ships is through a gate we
control.

See `agent-log.md` for concrete mistakes we actually caught.
