# tapdata-cicd-worker

A reusable GitHub Actions worker for deploying [TapData](https://tapdata.io) configurations (connections, migrate tasks, sync tasks, APIs, serving indexes) across multiple environments (dev / sit / lpt / aat / prod) with built-in human approval gates and tag-based rollback.

This repository is a **template**. Use it as the starting point for a customer-specific or team-specific TapData CI/CD setup.

## Two operating modes

- **Single-repo mode** — the worker repo *is* the deployment repo. Commit your project's `*_tapdata_export/` directory here; pushes to `main` deploy to dev, tags deploy to sit, and `workflow_dispatch` covers higher environments.
- **Multi-tenant mode** — the worker repo is a shared engine. Each team owns its own tenant repo with TapData configs and a thin caller workflow (`tenant-template/.github/workflows/`) that invokes this worker via `workflow_call`.

You can pick one mode and stick with it, or use both — the workflows are designed to support both transparently.

> **Convention: one project per repo.** Each repository holds exactly one `{project}_tapdata_export/` directory, so the project is auto-detected — no manual input needed. To deploy multiple projects, give each its own repo. (If a repo accidentally contains more than one `*_tapdata_export/`, deploy logs a warning and falls back to the one matching `vars.PROJECT_NAME` or the repo name, else the first.)

## Quick start

1. **Bootstrap the worker repo** — use this repo as a GitHub template (or fork / clone it) into a fresh repository, e.g. `your-org/tapdata-cicd-worker`.
2. **Register a self-hosted runner** with labels `self-hosted` and `tapdata` (the workflows pin to this label set so the runner can reach your TapData server).
3. **Configure GitHub Environments**: create `dev`, `sit`, `lpt`, `aat`, `prod` (or whatever subset you need). Add required reviewers on the higher environments to enable the approval gate.
4. **Configure secrets and variables** at org or repo level. Minimum required:
   - Secret `GH_DEPLOY_TOKEN` — fine-grained PAT with `Contents: Read` on this repo (and on tenant repos in multi-tenant mode).
   - Secret `{ENV}_TAPDATA_ACCESS_CODE` — TapData access code per environment, e.g. `DEV_TAPDATA_ACCESS_CODE`. Falls back to the un-prefixed `TAPDATA_ACCESS_CODE`.
   - Variable `{ENV}_TAPDATA_URL` — TapData server URL per environment, e.g. `DEV_TAPDATA_URL`. Falls back to the un-prefixed `TAPDATA_URL`.
   - (Optional) Secret `VAULT_ENCRYPTION_KEY` — enables AES-256 encryption of the `vault.json` artifact.
   - Connection credentials — one of three formats per connection, see [Connection credential formats](#connection-credential-formats) below. Unlike the platform keys above, connection keys take **no** `{ENV}_` prefix.
5. **Replace `conf/Task_Run_Order.json`** with your own MDM task DAG (`nodes` = task names, `edges` = upstream→downstream dependencies). The shipped file is an empty skeleton.
6. **(Multi-tenant only)** In each tenant repo, copy `tenant-template/.github/workflows/tapdata-deploy.yml` and `tapdata-rollback.yml` into `.github/workflows/`. Replace `{WORKER_REPO}` with `your-org/your-worker-repo` (e.g. `your-org/tapdata-cicd-worker`).

For full step-by-step instructions, see the documents under `docs/` (Chinese, with substitution placeholders).

## Connection credential formats

Each connection's credentials can be written in one of three formats. All three may coexist in one repo; `scripts/tapdata-deploy/generate-vault.sh` looks them up in the order below and **stops at the first match**.

| # | Format | Keys and where they live | Fields covered | Lookup scope | Plaintext surface | Rollback semantics | When to pick it |
|---|--------|--------------------------|----------------|--------------|-------------------|--------------------|-----------------|
| 1 | **URI** | `{CONNECTION}_URI` → **Secret** | Whole connection string, password included. **No database name** — that travels with the export bundle | **Exact connection name only** | **Smallest** — masked in logs | Rolling back the artifact rolls the database name back too | Existing connections that don't need a per-environment database name. Not recommended for new setups |
| 2 | **URL + USER + PASSWORD** | `{CONNECTION}_URL`, `{CONNECTION}_USER` → **Variable**; `{CONNECTION}_PASSWORD` → **Secret** | host, port, user, password. **No database name** | Exact → truncated prefix (`A_B_C_D` → `A_B`) → `DEFAULT_*` | Medium — host / port / user in plaintext | Same as above | Several connections share an address or credential and you want `DEFAULT_*` / prefix fallback |
| 3 | **DSN + PASSWORD** | `{CONNECTION}_DSN` → **Variable**, password position left **empty**; `{CONNECTION}_PASSWORD` → **Secret** (optional) | host, port, user, **database name**; MongoDB also keeps `replicaSet` / `authSource` | `_DSN` **exact name only**; `_PASSWORD` exact → prefix → `DEFAULT_PASSWORD` | **Largest** — address, database name, user and JDBC params readable by every collaborator, and in Actions logs | ⚠ **Does not roll back the database name** — the script reads the *current* variable value | **The only format with a per-environment database name.** Also when the address surface should be reviewable and diffable |

```
Variables:  ORDERS_MONGO_DSN = mongodb://tapuser:@mongo-sit.internal:27017/orders_sit?replicaSet=rs0
Secrets:    ORDERS_MONGO_PASSWORD = s3cr3t
```

- Environment isolation comes from **GitHub Environments** — configure the same key name under each Environment. Connection keys never carry a `DEV_` / `SIT_` prefix.
- A DSN carrying a **real password fails the deployment**; the error never echoes the DSN. If one was ever pasted in, the only remedy is to **rotate that password** — Variables are not masked and deleting one reclaims nothing.
- Before switching a connection to format 3, upgrade that environment's TapData first: an older TM **aborts the whole import** when it meets a `_DSN`-only connection.

Full guidance: [`docs/setup-checklist.md`](docs/setup-checklist.md) (checklist), [`docs/tapdata-cicd-usage.md`](docs/tapdata-cicd-usage.md) §5.4 (中文, day-to-day), [`docs/cicd-delivery-guide.md`](docs/cicd-delivery-guide.md) §6.3 (中文, delivery).

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
│   ├── workflows/                          # ACTIVE workflows — only files here auto-trigger / are callable via uses:
│   │   ├── tapdata-deploy.yml              # The LIVE deploy; tenant callers always point here. Swap its body from .github/deploy/ to change variant
│   │   └── tapdata-rollback.yml            # TapData rollback workflow
│   └── deploy/                             # Catalog of deploy variants (INERT — copy ONE over workflows/tapdata-deploy.yml to activate)
│       ├── tapdata-deploy-multi-job.yml             # multi-job · artifact v4 (one job per resource; gray "skipped" nodes)
│       ├── tapdata-deploy-matrix.yml                # matrix · artifact v4 (consolidated job; hides skipped; single approval)
│       └── tapdata-deploy-matrix-artifact-v3.yml    # matrix · artifact v3 (HA / GHES — older GHES lacks artifact v4)
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

The deploy and rollback workflows themselves require **no edits** for typical use — the project is auto-detected from the repo's single `*_tapdata_export/` directory (one project per repo), so `workflow_dispatch` only asks for the target environment. In multi-tenant mode the tenant caller passes the project explicitly (`vars.PROJECT_NAME`, else the tenant repo name).

## License

Add your own LICENSE file before publishing externally.
