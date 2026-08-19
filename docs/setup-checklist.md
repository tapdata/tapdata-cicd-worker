# Multi-Repo Multi-Tenant: Setup Checklist

> **Purpose: Pre-Go-Live Environment Preparation and Configuration Verification**

> Each team (tenant) owns an independent GitHub repository for their TapData configuration files.
> A shared worker repository serves as the unified deployment engine.
> The worker repo and tenant repos may reside in different GitHub organizations.

---

## Part 1: Customer IT/Ops Preparation

> The following items require internal approval and should be completed **before go-live**.

### 1.1 GitHub Instance & Organizations

- [ ] Confirm GitHub instance URL: `___________` (e.g. `https://github.example.com`)
- [ ] Confirm the worker repository full name (org/repo): `___________` (referred to as `{WORKER_REPO}`, e.g. `tapdata/tapdata-cicd-worker`)
- [ ] Confirm the organization for the tenant repositories: `___________` (referred to as `{team_org}`)

> The worker repo and tenant repos can be in the same organization or different organizations on the same GitHub instance.

### 1.2 GitHub Repositories

Create the following repositories:

- [ ] `{WORKER_REPO}` — shared deployment engine (CI/CD scripts and workflows); visibility must be set to **internal** (so tenant repos in `{team_org}` can reference its reusable workflows)
- [ ] `{team_org}/{tenant_repo}` — tenant repository (holds TapData export files for one project)

> Repository names above are suggestions — can be adjusted based on the actual project naming conventions.

### 1.3 GitHub User Account for TapData Engineer

- [ ] Create **1 GitHub account** for TapData implementation engineer
- [ ] Add to `{WORKER_REPO}` organization with write access to the worker repository (for pushing code)
- [ ] Add to `{team_org}` with admin access to tenant repositories (for configuring Environments, Secrets, and Variables)

> If the worker and tenant repos are in the same organization, only one membership is needed.

> Customer-side deployment approvers use their existing GitHub accounts — no additional account requests needed. They will be added as Environment reviewers in Part 2.

### 1.4 Self-hosted Runner

Provide a self-hosted GitHub Actions Runner that is **shared across all tenant repositories** under `{team_org}`:

- [ ] Runner is accessible to all tenant repositories (registration method is up to customer IT — organization-level, enterprise-level, or repository-level with sharing)
- [ ] Custom label **`tapdata`** is added to the Runner
- [ ] Dependencies installed: `git`, `bash`, `jq`
- [ ] Network (outbound): can reach GitHub (HTTPS)
- [ ] Network (internal): can reach the TapData server (host + port)
- [ ] Verify Runner status shows **Idle** and is available to the tenant repositories

### 1.5 TapData Servers (MDM Dev + Dev)

Provide **two** servers with the same specifications — one for the TapData local development environment, one for the Dev environment. TapData and MongoDB will be installed on each machine:

| Server | Purpose |
|---|---|
| MDM Dev Server | TapData local development and testing |
| Dev Server | Dev environment for CI/CD automated deployment |

**Specifications (per server):**

- [ ] CPU: 16 cores
- [ ] Memory: 128 GB
- [ ] Disk: 300 GB
- [ ] OS: Linux (Ubuntu 20.04+ recommended)

**Reference: SIT Environment Architecture**

```mermaid
graph LR
    subgraph Sources["Source PGDB · DC7 / PLTE"]
        HKPMI["HKPMI<br/>PostgreSQL"]
        HPI["HPI<br/>PostgreSQL"]
        CMS["CMS<br/>PostgreSQL"]
    end

    subgraph TapData["TapData Cluster"]
        API["API Server"]
        Mgmt["Management"]
        Engine["Flow Engine"]
        Client["API Client"]
    end

    subgraph MongoDB["MongoDB Cluster · MDM"]
        Primary["Mongo Primary"]
        Secondary1["Mongo Secondary"]
        Secondary2["Mongo Secondary"]
    end

    HKPMI -->|CDC| TapData
    HPI -->|CDC| TapData
    CMS -->|CDC| TapData
    TapData --> Primary
    Primary --- Secondary1
    Primary --- Secondary2
```

---

## Part 2: GitHub Configuration (TapData Team)

> Once Part 1 is complete, the following is done by the TapData deployment team.

### 2.1 Worker Repository (`{WORKER_REPO}`)

- [ ] Push worker code to the `main` branch
- [ ] Verify repository visibility is set to **internal** (Settings > General > Danger Zone > Change visibility)

> The worker workflow dynamically resolves its own repository name at runtime — no manual org name replacement is needed in workflow files.

### 2.2 Secrets & Variables (at `{team_org}` level)

Configure at `{team_org}` > **Settings** > **Secrets and variables** > **Actions**:

> All Secrets and Variables must be configured at the **`{team_org}`** level (or per-tenant repo level), because reusable workflows execute in the caller's context.

**Secrets:**

- [ ] `GH_DEPLOY_TOKEN` — Personal Access Token with read access to `{WORKER_REPO}` (for checking out worker scripts) and read/write access to tenant repos under `{team_org}`
- [ ] `SIT_TAPDATA_ACCESS_CODE`
- [ ] `LPT_TAPDATA_ACCESS_CODE`
- [ ] `VAULT_ENCRYPTION_KEY` — *(optional)* AES-256 key for encrypting vault.json artifact (32+ char random string). If not set, vault.json is uploaded as plaintext

**Variables:**

- [ ] `SIT_TAPDATA_URL` (e.g. `http://10.0.0.1:3030`)
- [ ] `LPT_TAPDATA_URL`
- [ ] `VAULT_TRANSPORT` — *(optional)* how vault.json is passed between Jobs. `auto` (default, unset): try `upload-artifact@v4`, and if it is unavailable fall back to a local file; `local`: skip artifacts entirely (no error log noise) — **use this on a single self-hosted runner where artifacts are not supported**; `artifact`: force native `upload-artifact@v4` and **never** use the local file — fails if v4 is unavailable. Local-file mode requires all Jobs to run on the **same** runner.
  > **GHES / older servers that only support artifact v3:** the live `.github/workflows/tapdata-deploy.yml` uses artifact **v4** and has no inline v3 fallback. Promote the **`.github/deploy/tapdata-deploy-matrix-artifact-v3.yml`** variant (artifact pinned to v3) into `.github/workflows/tapdata-deploy.yml` instead — see `docs/cicd-delivery-guide.md` §2.1.1.

### 2.3 Per-Tenant Repository Configuration

> Repeat the following for each tenant repository (e.g. `{team_org}/{tenant_repo}`).

**Environments:**

- [ ] Create Environment: `sit`
- [ ] Create Environment: `lpt`
- [ ] Create Environment: `deploy` — **add designated approvers as reviewers**

**Workflow file:**

- [ ] Create `.github/workflows/tapdata-deploy.yml` (replace `{WORKER_REPO}` and `{project}` with actual values):

```yaml
name: TapData Deploy

on:
  push:
    branches: [main]
    paths:
      - '{project}_tapdata_export/**'
    tags:
      - '{project}-*'
  workflow_dispatch:
    inputs:
      target_env:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - sit
          - lpt

jobs:
  deploy:
    uses: {WORKER_REPO}/.github/workflows/tapdata-deploy.yml@main
    with:
      project: {project}
      target_env: ${{ inputs.target_env || '' }}
      caller_repo: ${{ github.repository }}
      caller_sha: ${{ github.sha }}
      caller_event: ${{ github.event_name }}
      caller_ref: ${{ github.ref }}
      worker_repo: {WORKER_REPO}
    secrets: inherit
```

**Database credentials (per environment):**

Configure at tenant repo > **Settings** > **Secrets and variables** > **Actions**, under each Environment (`sit`, `lpt`, …).

**Pick one of three formats per connection.** All three may coexist in one repo; lookup stops at the first match, in the order below.

| # | Format | Keys and where they live | Fields covered | Lookup scope | Plaintext surface | Rollback semantics | When to pick it |
|---|--------|--------------------------|----------------|--------------|-------------------|--------------------|-----------------|
| 1 | **URI** | `{CONNECTION}_URI` → **Secret** | Whole connection string (password included). **No database name** — that travels with the export bundle | **Exact connection name only**: no prefix truncation, no `DEFAULT` fallback | **Smallest**: the whole string is a Secret, masked in Actions logs | Rolling back the artifact rolls the database name back too | Existing connections that don't need a per-environment database name — **leave them alone**. Not recommended for new setups |
| 2 | **URL + USER + PASSWORD** | `{CONNECTION}_URL`, `{CONNECTION}_USER` → **Variable**; `{CONNECTION}_PASSWORD` → **Secret** | host, port, user, password. **No database name** | Exact name → truncated prefix (before the 2nd `_`, `A_B_C_D` → `A_B`) → `DEFAULT_*` | Medium: host / port / user are plaintext | Same as above | Several connections share one address or credential and you want `DEFAULT_*` / prefix fallback to save keys |
| 3 | **DSN + PASSWORD** (new) | `{CONNECTION}_DSN` → **Variable** (password position left **empty**); `{CONNECTION}_PASSWORD` → **Secret** (**optional**) | host, port, user, **database name**; MongoDB also keeps `replicaSet` / `authSource` and other query params | `{CONNECTION}_DSN` **exact name only**; `{CONNECTION}_PASSWORD` exact → truncated prefix → `DEFAULT_PASSWORD` | **Largest**: address, database name, user and JDBC params are readable by every collaborator with repo read access, and land in Actions logs | ⚠ **Rollback does not roll back the database name** — the script reads the *current* variable value | **A per-environment database name is only possible here.** Also pick it when you want the address surface reviewable and diffable |

**Key naming — no environment prefix on connection keys:**

| Key kind | `{ENV}_` prefix | How it resolves |
|---|---|---|
| Platform (`TAPDATA_URL`, `TAPDATA_ACCESS_CODE`) | **Optional** | `{ENV}_TAPDATA_URL` first, falling back to `TAPDATA_URL` |
| Connection (`_DSN` / `_URI` / `_URL` / `_USER` / `_PASSWORD`) | **Never** | Only `{CONNECTION}_<suffix>` is looked up. `DEV_FDM_URI` is **not found** — that connection reports missing config |

Environment isolation comes from GitHub Environments: configure the **same** key name under each Environment with that environment's value.

`CONNECTION` must match the connection name in TapData; the script upper-cases it and spaces become underscores. ⚠ Names that collide once upper-cased (`foo_db` / `FOO_DB`) share one set of keys — under format 3 that means **one shared database**. Names containing hyphens, dots, spaces or non-ASCII, or starting with `GITHUB_`, cannot be used with format 3 at all (GitHub variable naming rules).

**Format 3 examples:**

| Type | Name | Example |
|---|---|---|
| Variable | `MDM_DSN` | `mongodb://tapuser:@host:27017/mdm_sit?replicaSet=rs0` |
| Variable | `HPI_SOURCE_DSN` | `readonly@10.0.1.10:5432/hpi_sit` |
| Secret | `HPI_SOURCE_PASSWORD` | `s3cret` |

- The password position must be **empty** — `user:@host/db` and `user@host/db` are both accepted. The password goes in the Secret.
- The three JDBC spellings are equivalent: `user@h:5432/db`, `jdbc:postgresql://user@h:5432/db`, `postgresql://user@h:5432/db`. The prefix is **discarded and never used to infer the database type**.
- MongoDB DSNs are kept whole (seed lists, `replicaSet`, `authSource`, `mongodb+srv://`). JDBC `?` params are **dropped this release** with a named warning; MongoDB query params are kept.
- Missing `{CONNECTION}_PASSWORD`, database name, or user is **not** an error: the target's existing value is kept and a warning names exactly what was missing.
- ⚠ A DSN carrying a **real password fails the deployment**, and the error never echoes the DSN. If one was ever pasted in, the only remedy is to **rotate that password** — Variables are not masked, and deleting the variable reclaims nothing.

**Before switching a connection to format 3:**

- [ ] Target environment's TapData is already upgraded — an older TM **aborts the whole import** when it meets a `_DSN`-only connection (not just that connection). Each environment upgrades separately.
- [ ] New key added *before* the old one is removed (format 3 wins while both exist, so a deploy can verify it first).
- [ ] `DEFAULT_PASSWORD` **kept**, if the repo uses it — `_DSN` is exact-name only, but `_PASSWORD` still falls back.

- [ ] `sit` environment database credentials configured
- [ ] `lpt` environment database credentials configured

**Optional repository variable (only when project name differs from repo name):**

- [ ] `PROJECT_NAME` — set on the tenant repo if the TapData project name and `{project}_tapdata_export/` directory prefix should differ from the repo name. Leave unset to default to the repo name.

> **Project name resolution priority** (highest first):
> 1. `workflow_dispatch` manual input `project` (per-run override)
> 2. Repository variable `vars.PROJECT_NAME`
> 3. Repository name (`github.event.repository.name`)

**TapData platform:**

- [ ] Create a project on TapData platform whose name matches the resolved project name. By default this is the tenant repository name (e.g. repo `your-tenant-repo` → project `your-tenant-repo`). If `PROJECT_NAME` is set, the project name on TapData must match that variable's value instead.

---

## Part 3: MDM Dev Environment Setup (TapData Team)

> Once the MDM Dev Server (1.5) is ready, the TapData team will install and configure the software.

### 3.1 Install & Configure

- [ ] Install MongoDB on the MDM Dev Server
- [ ] Install TapData on the MDM Dev Server
- [ ] Configure all required parameters (database connection, ports, credentials, etc.)
- [ ] Verify TapData starts successfully and is accessible

### 3.2 TapData Platform Configuration

- [ ] Configure Connections on the TapData platform (local dev)
- [ ] Configure and start Migration / Sync Tasks on the TapData platform (local dev)
- [ ] Publish APIs on the TapData platform (local dev)
