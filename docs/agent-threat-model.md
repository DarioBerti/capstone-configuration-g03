# Agent threat model

> Required by the capstone: reason about the blast radius of a coding agent inside our delivery loop.

## What the agent can and cannot do (least privilege)

| The agent has | The agent does NOT have |
|---|---|
| read/write access to a local clone of both repos | any cluster credentials or kubeconfig |
| the ability to propose branches / PRs (Git only) | registry push creds (`ACR_*`) or the `CONFIG_REPO_PAT`: those live only as GitHub Actions secrets in the application repo |

Direct pushes to `main` are not blocked by GitHub (private repos on the free plan have no branch
protection), so "everything goes through a PR" is a **team process rule**, enforced by review habits,
not by the platform.

Same principle as CI: the agent influences the cluster **only** through Git: it can never touch the
cluster or the registry directly. Argo CD reconciles what lands on `main`.

## The gates before an agent change reaches the cluster

1. **Human review** on the PR: the primary gate
2. **Application repo, on the PR** (`pr-check.yml`): the test suites of every changed service and
   the frontend type-check/build must pass before merge. No credentials, no image push.
3. **Application repo, after merge** (`ci.yml`): tests run again, the image is built and pushed,
   and the tag is bumped in the config repo; only then does Argo CD roll it out.
4. **Config repo**: no CI runs on PRs today; a broken chart is caught by human review and, at worst,
   by Argo CD failing to render/sync (it keeps the last healthy state). Adding `helm lint` +
   `kubeconform` on config-repo PRs is a known gap / future improvement, not an active gate.
