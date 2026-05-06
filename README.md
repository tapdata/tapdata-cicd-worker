# tapdata-cicd-worker

A reusable GitHub Actions worker for deploying [TapData](https://tapdata.io) configurations (connections, migrate tasks, sync tasks, APIs) across multiple environments (dev / sit / lpt / aat / prod) with built-in human approval gates and tag-based rollback.

This repository is a **template**. Use it as the starting point for a customer-specific or team-specific TapData CI/CD setup.

## Two operating modes

- **Single-repo mode** — the worker repo *is* the deployment repo. Commit your `*_tapdata_export/` directories here; pushes to `main` deploy to dev, tags deploy to sit, and `workflow_dispatch` covers higher environments.
- **Multi-tenant mode** — the worker repo is a shared engine. Each team owns its own tenant repo with TapData configs and a thin caller workflow (`tenant-template/.github/workflows/`) that invokes this worker via `workflow_call`.

You can pick one mode and stick with it, or use both — the workflows are designed to support both transparently.

## Quick start

1. **Bootstrap the worker repo** — use this repo as a GitHub template (or fork / clone it) into a fresh repository, e.g. `your-org/tapdata-cicd-worker`.
2. **Register a self-hosted runner** with labels `self-hosted` and `tapdata` (the workflows pin to this label set so the runner can reach your TapData server).
3. **Configure GitHub Environments**: create `dev`, `sit`, `lpt`, `aat`, `prod` (or whatever subset you need). Add required reviewers on the higher environments to enable the approval gate.
4. **Configure secrets and variables** at org or repo level. Minimum required:
   - Secret `GH_DEPLOY_TOKEN` — fine-grained PAT with `Contents: Read` on this repo (and on tenant repos in multi-tenant mode).
   - Secret `{ENV}_TAPDATA_ACCESSCODE` — TapData access code per environment, e.g. `DEV_TAPDATA_ACCESSCODE`.
   - Variable `TAPDATA_URL` — TapData server URL per environment.
   - (Optional) Secret `VAULT_ENCRYPTION_KEY` — enables AES-256 encryption of the `vault.json` artifact.
   - Connection-level secrets (`{CONNECTION_NAME}_URI` / `{CONNECTION_NAME}_user` / `DEFAULT_*`) — see `scripts/tapdata-deploy/generate-vault.sh` for the resolution order.
5. **Replace `conf/Task_Run_Order.json`** with your own MDM task DAG (`nodes` = task names, `edges` = upstream→downstream dependencies). The shipped file is an empty skeleton.
6. **(Multi-tenant only)** In each tenant repo, copy `tenant-template/.github/workflows/tapdata-deploy.yml` and `tapdata-rollback.yml` into `.github/workflows/`. Replace `{WORKER_REPO}` with `your-org/your-worker-repo` (e.g. `your-org/tapdata-cicd-worker`).

For full step-by-step instructions, see the documents under `docs/` (Chinese, with substitution placeholders).

## Documentation

| Doc | Audience | Scope |
|---|---|---|
| [`docs/setup-checklist.md`](docs/setup-checklist.md) | Delivery engineer + customer ops | Pre-go-live initialization checklist (uses `{worker-org}` / `{tenant-org}` placeholders) |
| [`docs/cicd-delivery-guide.md`](docs/cicd-delivery-guide.md) | Delivery engineer (中文) | End-to-end setup guide, 10 sections, covers GitHub topology, runner install, troubleshooting |
| [`docs/tapdata-cicd-usage.md`](docs/tapdata-cicd-usage.md) | Customer ops / dev team (中文) | Day-to-day usage manual covering 5-environment progressive rollout (Local → Dev → SIT → AAT → Prod) and rollback |

## Directory structure

```
tapdata-cicd-worker/
├── .github/
│   └── workflows/                          # Reusable workflow definitions (used by this repo and by tenant callers)
│       ├── tapdata-deploy.yml              # TapData deployment workflow (single-repo + workflow_call)
│       └── tapdata-rollback.yml            # TapData rollback workflow (single-repo + workflow_call)
├── conf/
│   └── Task_Run_Order.json                 # Task DAG execution order — replace with your own
├── scripts/                                # Automation scripts invoked by the workflows
│   ├── common/                             # Shared utilities
│   │   ├── compress-files.sh               # Compress export files
│   │   ├── consolidate-previews.sh         # Merge dry-run preview results
│   │   ├── get-token.sh                    # Retrieve TapData access token
│   │   ├── import-resource.sh              # Import resources via TapData API
│   │   ├── preview-resource.sh             # Dry-run preview (no changes applied)
│   │   ├── stop-tasks.sh                   # Stop running tasks
│   │   └── vault-crypto.sh                 # vault.json AES-256 encrypt/decrypt
│   ├── tapdata-deploy/                     # Deployment-specific scripts
│   │   ├── detect-project.sh               # Detect project from changed export paths
│   │   ├── generate-report.sh              # Build deployment summary report
│   │   ├── generate-vault.sh               # Build secrets config from GitHub Secrets
│   │   └── validate-inputs.sh              # Validate workflow input parameters
│   ├── tapdata-rollback/                   # Rollback-specific scripts
│   │   ├── clean-resources.sh
│   │   ├── resolve-tag.sh
│   │   ├── start-and-publish.sh
│   │   ├── unpublish-apis.sh
│   │   └── validate-inputs.sh
│   └── tapdata-rebuild/                    # Rebuild-specific scripts
│       ├── list-rebuild-tasks.sh
│       ├── reset-tasks.sh
│       ├── run-tasks.sh
│       └── validate-inputs.sh
├── tenant-template/                        # Templates copied into TENANT repos (not used by the worker itself)
│   └── .github/
│       └── workflows/
│           ├── tapdata-deploy.yml          # Caller workflow — replace {WORKER_REPO}
│           └── tapdata-rollback.yml        # Caller workflow — replace {WORKER_REPO}
├── docs/                                   # Setup and usage guides
│   ├── setup-checklist.md
│   ├── cicd-delivery-guide.md
│   └── tapdata-cicd-usage.md
└── README.md
```

## What needs customization before first use

| File | Change |
|---|---|
| `conf/Task_Run_Order.json` | Fill in your MDM task DAG (currently empty skeleton). |
| GitHub repo settings | Environments, secrets, variables, self-hosted runner. |
| Tenant repos (multi-tenant only) | Drop in `tenant-template/.github/workflows/*` and replace `{WORKER_REPO}`. |

The deploy and rollback workflows themselves require **no edits** for typical use — `project` is auto-detected from `*_tapdata_export/` paths on push, and tunable via `workflow_dispatch` input.

## License

Add your own LICENSE file before publishing externally.
