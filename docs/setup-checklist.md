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

**Database credentials (repo-level):**

Configure at tenant repo > **Settings** > **Secrets and variables** > **Actions**:

**MongoDB connections** (`FDM`, `MDM`) — use URI format:

| Type | Name | Example |
|---|---|---|
| Secret | `FDM_URI` | `mongodb://user:pass@host:27017/db` |
| Secret | `MDM_URI` | `mongodb://user:pass@host:27017/db` |

**PostgreSQL connections** (all others) — use split format:

| Type | Name |
|---|---|
| Variable | `{NAME}_URL` |
| Variable | `{NAME}_USER` |
| Secret | `{NAME}_PASSWORD` |

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
