# TapData CI/CD 使用说明

> 本文档面向运维和研发团队，从零开始完成 TapData 多租户 CI/CD 系统的搭建与日常使用。

---

## 约定

本文默认 **Worker 仓库和租户仓库位于不同的 GitHub 组织**（跨组织模式，常用于平台团队与业务团队分治）。若两者位于同一组织，`{worker-org}` 与 `{tenant-org}` 填相同值即可，其他步骤完全一致。

本文使用以下占位符，使用时替换为实际值：

| 占位符 | 说明 | 示例 |
|-------|-----|-----|
| `{worker-org}` | Worker 仓库所在组织 | `platform-org` |
| `{tenant-org}` | 租户仓库所在组织 | `business-org` |
| `{worker-repo}` | Worker 仓库名 | `tapdata-cicd-worker` |
| `{tenant-repo}` | 租户仓库名 | `tenant-a` |
| `{tenant}` | 租户标识（与租户仓库名一致）| `tenant-a` |
| `{ENV}` | 环境大写标识 | `DEV` / `SIT` / `AAT` / `PROD` |

> **同组织场景**：`{worker-org}` = `{tenant-org}`，Worker 仓库可见性仍需设为 **Internal**（或 Public），租户仓库通过 `uses: {worker-org}/{worker-repo}/...` 引用即可。

---

## 1. 前置资源清单

正式开工前，请确认以下资源已就绪或已规划。数量 `N` 表示租户团队数量。

### 1.1 GitHub 资源

| 项 | 数量 | 说明 |
|---|-----|-----|
| GitHub 组织 | 1 或 2 | Worker 组织 + 租户组织（可合并为同一个） |
| Worker 仓库 | 1 | Internal 可见性，位于 `{worker-org}` |
| 租户仓库 | N | 每个租户团队一个，位于 `{tenant-org}` |
| PAT | 1 或 2 | Classic PAT × 1 或 Fine-grained PAT × 2 |
| 审批人账号 | ≥ 1 | 作为 `deploy` Environment 的 Required reviewer |

### 1.2 Self-hosted Runner

| 项 | 规格 | 说明 |
|---|-----|-----|
| Runner 机器 | ≥ 2 台 | Linux（Ubuntu 20.04+），2 核 4GB 起步 |
| 依赖 | - | `git` / `bash` / `jq` / `curl` / `openssl` / `tar` |
| 出方向网络 | - | HTTPS 可达 GitHub 实例 |
| 入方向网络 | - | 可达所有环境的 TapData Server 端口 |

### 1.3 TapData 环境（每环境一套）

| 环境 | 用途 | 部署方式 |
|-----|-----|---------|
| Local Dev | 工程师本地开发 | 手动 |
| Dev | 开发集成 | PR 合并自动触发 |
| SIT | 系统集成测试 | Git Tag 自动触发 |
| AAT | 用户验收测试 | 手动触发 |
| Prod | 生产 | 手动触发 + 审批 |

每个环境需要：

| 项 | 说明 |
|---|-----|
| TapData Server | Management + Flow Engine + API Server，建议 16C / 128G / 300G |
| MongoDB 集群 | 承载 FDM 和 MDM 数据 |
| 业务源数据库 | PostgreSQL / MySQL / Oracle 等，由业务系统提供 |
| TapData 账号 | 每个租户一个角色 + 用户，生成 Access Code |
| 网络连通 | Runner 可达 TapData Server；TapData 可达源库和 MongoDB |

### 1.4 数据库凭据

| 项 | 说明 |
|---|-----|
| MongoDB FDM/MDM 凭据 | 每个租户每个环境一套（建议按 DB 或 Collection 级隔离） |
| 源库账号 | 每个连接每个环境一套（最小权限原则：只读或只需范围） |

### 1.5 人员

| 角色 | 职责 |
|-----|-----|
| 平台运维 | 维护 Worker 仓库、Runner、组织级 Secrets/Variables |
| 租户工程师 | 维护租户仓库、在 Local Dev 配置资源、触发导出 |
| 部署审批人 | 在 `deploy` Environment 批准部署 |
| DBA | 提供数据库账号、配置权限隔离 |

---

## 2. 触发机制概览

系统采用 **"Local Dev → Dev → SIT → AAT → Prod"** 的渐进式部署模型，不同环境的触发方式不同。

```mermaid
flowchart LR
    LocalDev["Local Dev<br/>(TapData 开发平台)"]
    Dev["Dev<br/>环境"]
    Sit["SIT<br/>环境"]
    Aat["AAT<br/>环境"]
    Prod["Prod<br/>环境"]

    LocalDev -->|导出 → PR 合并到 main<br/>（自动触发）| Dev
    Dev -->|创建 Git Tag<br/>（自动触发）| Sit
    Sit -->|workflow_dispatch<br/>（手动触发）| Aat
    Aat -->|workflow_dispatch<br/>（手动触发）| Prod

    classDef auto fill:#d4edda,stroke:#28a745
    classDef manual fill:#fff3cd,stroke:#ffc107
    class Dev,Sit auto
    class Aat,Prod manual
```

| 环境 | 触发方式 | 说明 |
|-----|--------|------|
| **Local Dev** | 人工操作 | TapData 工程师在本地平台配置资源、导出到 GitHub |
| **Dev** | PR 合并到 `main` 自动触发 | 用于开发变更的自动集成 |
| **SIT** | 创建 Git Tag（如 `v1.0.0`）自动触发 | 通过 Dev 验证后版本化提测 |
| **AAT** | `workflow_dispatch` 手动触发 | 运维人员在 GitHub Actions 页面手动触发 |
| **Prod** | `workflow_dispatch` 手动触发（需审批门） | 生产部署，需指定审批人批准 |

> 所有环境的部署都经过 GitHub Environment `deploy` 审批门，审批人在 GitHub Actions 页面点击 **Approve** 后才继续执行。

---

## 3. GitHub 仓库创建

本系统至少需要 **2 个仓库**：1 个 Worker 仓库 + N 个租户（config）仓库。

### 3.1 仓库清单

| 仓库 | 所在组织 | 可见性 | 用途 |
|-----|---------|-------|-----|
| `{worker-org}/{worker-repo}` | Worker 组织 | **Internal** | 共享部署引擎：存放 workflows + scripts |
| `{tenant-org}/{tenant-repo}` | 租户组织 | Internal / Private | 租户仓库：存放该团队的 TapData 导出配置 |

> **跨组织引用要求**：Worker 仓库必须设为 **Internal**（同一 GitHub Enterprise 内可跨组织访问）或 **Public**，租户仓库才能通过 `uses: {worker-org}/{worker-repo}/...` 引用可复用工作流。Private 不支持跨组织引用。

### 3.2 创建步骤

**在 Worker 组织下创建 Worker 仓库：**

1. 打开 `{worker-org}` 组织页 → 点击 **New repository**
2. 填写仓库名（如 `tapdata-cicd-worker`）
3. 选择 **Internal** 可见性
4. 勾选 Initialize with README
5. 点击 **Create repository**

**在租户组织下创建租户仓库：**

1. 打开 `{tenant-org}` 组织页 → 点击 **New repository**
2. 填写仓库名（如 `tenant-a`）
3. 选择 **Internal** 或 **Private**（仅本组织内部可见即可）
4. 点击 **Create repository**
5. 每新增一个租户团队，重复此步骤

### 3.3 修改已有仓库可见性

```
仓库页面 → Settings → General → Danger Zone
→ Change repository visibility → Internal → 确认
```

---

## 4. 申请 Personal Access Token（PAT）

PAT 有两个用途，**建议使用同一个 Token 同时覆盖**：

| 用途 | 使用者 | 所需权限 |
|-----|-------|---------|
| GitHub Actions 拉取 Worker 脚本 | Runner 机器 | Worker 仓库 Contents（读） |
| TapData 平台导出创建 PR | TapData 服务 | 租户仓库 Contents（读写） + Pull requests（读写） |

### 4.1 创建 Fine-grained PAT（推荐）

Fine-grained PAT 的 Resource owner 只能选择一个组织，**跨组织场景需要创建两个 PAT**（或改用 Classic PAT，见 4.2）。

**PAT-A：用于访问 Worker 组织**

1. GitHub 头像菜单 → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens**
2. 点击 **Generate new token**
3. 填写：
   - **Token name**：`tapdata-cicd-worker-read`
   - **Expiration**：按安全策略选择（如 90 天）
   - **Resource owner**：`{worker-org}`
   - **Repository access**：`Only select repositories` → 勾选 `{worker-repo}`
4. **Repository permissions**：
   - `Contents` → **Read-only**
   - `Metadata` → **Read-only**（自动勾选）
5. 点击 **Generate token**，立即复制

**PAT-B：用于操作租户组织**

1. 重复以上流程
2. 填写：
   - **Token name**：`tapdata-cicd-tenant-rw`
   - **Resource owner**：`{tenant-org}`
   - **Repository access**：`Only select repositories` → 勾选所有租户仓库
3. **Repository permissions**：
   - `Contents` → **Read and write**
   - `Pull requests` → **Read and write**
   - `Metadata` → **Read-only**
4. 生成后立即复制

> 同组织场景下，两个 PAT 可合并为一个：Resource owner 选择该组织，同时勾选 Worker 仓库（读）和租户仓库（读写）。

### 4.2 Classic PAT 备选方案

Classic PAT 不区分 Resource owner，**一个 Token 即可同时覆盖 Worker 和租户组织**（推荐跨组织场景使用）。

如果组织不支持 Fine-grained 或为简化管理，创建 Classic PAT：
- 勾选 `repo`（包含所有子权限）
- 勾选 `workflow`（如需从 Token 触发工作流）
- 要求 Token 持有人在 `{worker-org}` 和 `{tenant-org}` 都是成员且具备对应访问权限

---

## 5. 仓库初始化

### 5.1 初始化 Worker 仓库

**Step 1：从官方源获取 Worker 代码**

官方 Worker 代码托管在：**https://github.com/tapdata/tapdata-cicd-worker**

```bash
# 从官方源克隆（只取代码，不保留原仓库的 git 历史）
git clone --depth 1 https://github.com/tapdata/tapdata-cicd-worker.git /tmp/worker-source
rm -rf /tmp/worker-source/.git

# 克隆你自己的 Worker 仓库
git clone https://github.com/{worker-org}/{worker-repo}.git
cd {worker-repo}

# 将官方代码复制进来
cp -r /tmp/worker-source/. .
```

**Step 2：按需修改 Worker 工作流参数**

Worker 仓库主要供租户仓库通过 `workflow_call` 调用；但它自身的 `workflow_dispatch` 入口允许在 Worker 仓库直接手动测试。以下字段**请按项目实际情况修改**：

在 `.github/workflows/tapdata-deploy.yml` 的 `workflow_dispatch.inputs` 段：

```yaml
workflow_dispatch:
  inputs:
    target_env:
      description: 'Target environment'
      required: true
      type: choice
      options:
        - dev          # 按项目实际启用的环境调整
        - sit
        - lpt
        # - aat        # 若有 AAT 环境，添加此行
        # - prod       # 若有 Prod 环境，添加此行
    project:
      description: 'Project name'
      required: true
      type: choice
      default: <你的默认项目名>        # ← 必改：填一个实际项目名
      options:
        - <project-1>                  # ← 必改：列出所有租户项目名
        - <project-2>                  # ← 必改
```

同样检查 `.github/workflows/tapdata-rollback.yml` 里的 `workflow_dispatch.inputs.target_env.options` 和 `project.options`，保持一致。

> 这两个 `workflow_dispatch` 入口仅在"从 Worker 仓库直接触发"时生效。正常多租户模式下由租户仓库的工作流调用 `workflow_call`，此处 options 不影响租户调用。因此若你完全不使用 Worker 直接触发，可保留默认值。

**Step 3：提交推送**

```bash
git add .
git commit -m "feat: initial worker repo"
git push origin main
```

验证：仓库的 `.github/workflows/` 下应有 `tapdata-deploy.yml` 和 `tapdata-rollback.yml`。

### 5.2 初始化租户仓库

```bash
git clone https://github.com/{tenant-org}/{tenant-repo}.git
cd {tenant-repo}
mkdir -p .github/workflows
```

复制 Worker 仓库 `tenant-template/.github/workflows/tapdata-deploy.yml` 和 `tapdata-rollback.yml` 到当前仓库的 `.github/workflows/`，**将两处 `{WORKER_REPO}` 替换为跨组织的完整路径 `{worker-org}/{worker-repo}`**。

示例 `tapdata-deploy.yml`：

```yaml
name: TapData Deploy

on:
  push:
    branches: [main]
    paths:
      - '*_tapdata_export/**'
    tags:
      - '*'
  workflow_dispatch:
    inputs:
      target_env:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - dev
          - sit
          - aat
          - prod
      project:
        description: 'Project name (留空则取 vars.PROJECT_NAME，再回落到仓库名)'
        required: false
        type: string
        default: ''

jobs:
  deploy:
    uses: "{worker-org}/{worker-repo}/.github/workflows/tapdata-deploy.yml@main"
    with:
      project: ${{ inputs.project || vars.PROJECT_NAME || github.event.repository.name }}
      target_env: ${{ inputs.target_env || '' }}
      caller_repo: ${{ github.repository }}
      caller_sha: ${{ github.sha }}
      caller_event: ${{ github.event_name }}
      caller_ref: ${{ github.ref }}
      worker_repo: "{worker-org}/{worker-repo}"
    secrets: inherit
```

提交：

```bash
git add .github/workflows/
git commit -m "feat: add tapdata cicd workflows"
git push origin main
```

### 5.3 配置组织级 Secrets 与 Variables

> **重要：所有 Secrets 和 Variables 必须配置在 `{tenant-org}`（租户组织）下**。
> Worker 仓库的工作流通过 `workflow_call` 被租户仓库调用，执行时继承的是 **Caller（租户仓库）** 的 Secrets 上下文，与 Worker 组织的 Secrets 无关。
> Worker 组织下无需配置任何 Secrets / Variables。

进入 **`{tenant-org}` → Settings → Secrets and variables → Actions**。

**Secrets**（加密）：

| 名称 | 说明 |
|-----|-----|
| `GH_DEPLOY_TOKEN` | 第 4 节创建的 PAT（Classic 用同一个；Fine-grained 用 PAT-A + PAT-B 的组合方案见下文） |
| `DEV_TAPDATA_ACCESS_CODE` | Dev 环境 TapData Access Code |
| `SIT_TAPDATA_ACCESS_CODE` | SIT 环境 TapData Access Code |
| `AAT_TAPDATA_ACCESS_CODE` | AAT 环境 TapData Access Code |
| `PROD_TAPDATA_ACCESS_CODE` | Prod 环境 TapData Access Code |
| `VAULT_ENCRYPTION_KEY` | （可选）vault.json AES-256 加密密钥（32+ 字符随机串） |

**Variables**（明文）：

| 名称 | 示例 |
|-----|-----|
| `DEV_TAPDATA_URL` | `http://10.0.0.1:3030` |
| `SIT_TAPDATA_URL` | `http://10.0.0.2:3030` |
| `AAT_TAPDATA_URL` | `http://10.0.0.3:3030` |
| `PROD_TAPDATA_URL` | `http://10.0.0.4:3030` |

> Access Code 获取方式：以 admin 账号登录对应环境的 TapData → 系统设置 → 用户管理 → 点击用户 → 复制 Access Code。

**跨组织 PAT 组合说明**：若使用 Fine-grained（两个 PAT），`GH_DEPLOY_TOKEN` 填 PAT-B（租户组织读写），同时额外配置 `GH_WORKER_TOKEN = PAT-A`（Worker 组织只读）；若使用 Classic PAT 则只需 `GH_DEPLOY_TOKEN` 一个。

### 5.4 配置租户仓库级 Secrets（数据库凭据）

进入租户仓库 → **Settings → Secrets and variables → Actions**。

**MongoDB 连接（URI 格式）：**

| 类型 | 名称 | 示例 |
|-----|-----|------|
| Secret | `{ENV}_FDM_URI` | `mongodb://user:pass@host:27017/fdm` |
| Secret | `{ENV}_MDM_URI` | `mongodb://user:pass@host:27017/mdm` |

对 `DEV` / `SIT` / `AAT` / `PROD` 分别配置一套。

**PostgreSQL / MySQL 等分字段格式：**

| 类型 | 名称 | 示例 |
|-----|-----|------|
| Variable | `{ENV}_{CONNECTION}_URL` | `DEV_SOURCE_DB_A_URL` = `10.0.1.10:5432` |
| Variable | `{ENV}_{CONNECTION}_USER` | `DEV_SOURCE_DB_A_USER` = `readonly` |
| Secret | `{ENV}_{CONNECTION}_PASSWORD` | `DEV_SOURCE_DB_A_PASSWORD` = `xxx` |

> `CONNECTION` 名称需与 TapData 平台上的连接名保持一致（大写，空格替换为下划线）。

### 5.5 创建 GitHub Environments

进入租户仓库 → **Settings → Environments → New environment**，依次创建：

| 环境 | Protection Rules |
|-----|-----------------|
| `dev` | 无 |
| `sit` | 无 |
| `aat` | 无 |
| `prod` | 无 |
| `deploy` | **Required reviewers：填入审批人账号** |

> `deploy` 是所有环境部署的共用审批门，运行到连接导入步骤时会暂停等待审批。

---

## 6. 安装 Self-hosted Runner

所有环境的部署作业都运行在 Runner 上，Runner 必须能访问 GitHub 实例和对应 TapData 服务器。

> **跨组织 Runner 策略**：Runner 需在 **`{tenant-org}` 下注册**（因为 workflow 在 Caller 租户仓库上下文执行）。如果租户组织多、管理复杂，可将 Runner 注册到 GitHub Enterprise 级别，供所有组织共享。

### 6.1 Runner 要求

| 项目 | 要求 |
|-----|-----|
| 操作系统 | Linux（Ubuntu 20.04+） |
| 依赖 | `git`、`bash`、`jq`、`curl`、`openssl` |
| 网络（出）| 可访问 GitHub 实例（HTTPS 443） |
| 网络（内）| 可访问所有 TapData 服务器端口 |

### 6.2 安装步骤

```bash
# 1. 安装依赖
sudo apt-get update
sudo apt-get install -y git jq curl openssl tar

# 2. 创建运行目录
sudo mkdir -p /opt/github-runner && cd /opt/github-runner

# 3. 在 {tenant-org} 组织页获取 Runner 下载链接和注册 Token：
#    {tenant-org} → Settings → Actions → Runners → New self-hosted runner

# 4. 下载 Runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.x.x/actions-runner-linux-x64-2.x.x.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# 5. 配置
./config.sh \
  --url https://github.com/{tenant-org} \
  --token {REGISTRATION_TOKEN} \
  --name "tapdata-runner-01" \
  --labels "tapdata" \
  --unattended

# 6. 注册为 systemd 服务
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

### 6.3 验证 Runner

进入 **`{tenant-org}` → Settings → Actions → Runners**，确认：

- Runner 显示 **Idle**
- Runner 标签包含 `tapdata`
- Runner 可被所有租户仓库使用（组织级 Runner 默认全组织可用）

### 6.4 Runner 数量建议

- 单 Runner 一次只能运行一个 workflow 作业；建议 **至少部署 2 个 Runner**，避免高峰期排队
- 每个 Runner 都要具备访问所有环境 TapData 服务器的能力

---

## 7. 搭建 TapData 多环境

### 7.1 环境规划

| 环境 | 用途 | 部署方式 |
|-----|-----|---------|
| **Local Dev** | 本地开发调试，工程师直接在 UI 上配置 | 人工配置，无 CI/CD |
| **Dev** | 开发集成环境，由 PR 合并自动部署 | CI/CD 自动 |
| **SIT** | 系统集成测试，由 Tag 自动部署 | CI/CD 自动 |
| **AAT** | 用户验收测试 | CI/CD 手动触发 |
| **Prod** | 生产环境 | CI/CD 手动触发 + 审批 |

### 7.2 每个环境的组件

每个 TapData 环境都包含：

- **TapData Server**（Management + Flow Engine + API Server）
- **MongoDB Cluster**（作为 FDM/MDM 的存储）
- **业务源数据库**（PostgreSQL / MySQL / Oracle 等，由业务系统提供）

### 7.3 初始化步骤（每个环境都需执行）

1. 安装 MongoDB 和 TapData，启动管理控制台
2. admin 账号登录，创建租户角色 + 用户，生成 Access Code
3. 把服务地址和 Access Code 配置到 GitHub 组织级变量：`{ENV}_TAPDATA_URL` 和 `{ENV}_TAPDATA_ACCESS_CODE`（见 5.3）

### 7.4 Local Dev 与其他环境的差异

| 维度 | Local Dev | Dev / SIT / AAT / Prod |
|-----|-----------|------------------------|
| 资源创建 | 工程师在 UI 上手工创建 | 由 CI/CD 从配置文件导入 |
| 连接凭据 | 工程师在 UI 明文填写 | 从 GitHub Secrets 动态注入 |
| GitHub 集成 | 配置 GitHub URL + PAT | 无需 |
| 角色用户 | 角色定义来源 | 仅用于运行部署任务 |

---

## 8. Deploy 流程

本节走一遍完整的端到端部署流程。

### 8.1 准备数据库资源（Local Dev）

在 Local Dev 服务器上，确保以下资源就绪：

- [ ] 所有业务源数据库可访问（IP + 端口 + 账号）
- [ ] MongoDB 集群启动，FDM/MDM 数据库用户已创建
- [ ] 各连接的只读 / 读写账号已由 DBA 提供

### 8.2 在 TapData Local Dev 创建资源

以租户用户登录 **Local Dev**，按业务需要创建：连接（含源库 + FDM + MDM）→ 迁移任务 → 同步任务 → API，并通过试运行 / Validate 确认数据流转正常。

> 具体操作请参考 TapData 官方文档，本指南不再赘述。

### 8.3 创建 TapData 项目并配置 GitHub 导出

在 TapData 创建项目，将 8.2 资源加入项目，并配置 GitHub 导出：

- **项目名**：按以下优先级解析（自高到低）——① `workflow_dispatch` 手动输入的 `project`；② 租户仓库 `vars.PROJECT_NAME`；③ 仓库名（`{tenant-repo}`）。下文以 `{project}` 表示解析结果，TapData 项目名需与之一致
- **GitHub URL**：`https://github.com/{tenant-org}/{tenant-repo}`
- **GitHub Token**：第 4 节申请的 PAT
- **分支**：`main`
- **导出目录**：`{project}_tapdata_export`

### 8.4 导出到 GitHub → 触发 Dev 部署

1. 项目页点击 **导出到 GitHub**
2. TapData 将项目资源序列化为 JSON，在租户仓库创建一个 **Pull Request**
3. 进入租户仓库 → **Pull requests** 查看并 Review
4. 合并 PR 到 `main`
5. 合并动作触发 `TapData Deploy` workflow（因为路径 `*_tapdata_export/**` 被修改），自动部署到 **Dev** 环境
6. 进入 **Actions** 页面观察运行进度
7. 运行到 `deploy-connections` 步骤时暂停，等待 `deploy` 环境审批：
   - 点击 **Review deployments** → 勾选 `deploy` → **Approve and deploy**
8. 后续 Job 继续执行：preview → import connections → import migrate tasks → import sync tasks → import apis → report

### 8.5 Dev 环境验证

登录 Dev 环境的 TapData 平台，确认：

- 项目资源（连接 / 任务 / API）与 Local Dev 一致
- 连接的账号 / 密码 / 主机已被替换为 Dev 环境的值（而非 Local Dev）
- 测试连接通过，启动任务、发布 API 后业务运行正常

如有异常，回到 Local Dev 修复后重新导出（8.4）。

### 8.6 创建 Tag → 自动部署 SIT

Dev 验证通过后，创建版本 Tag 触发 SIT 部署：

```bash
cd {tenant-repo}
git checkout main
git pull

git tag v1.0.0
git push origin v1.0.0
```

- 进入 **Actions** 页面，确认新的 workflow run 被 Tag 触发
- 同样经过 `deploy` 审批门
- 部署完成后，登录 SIT 环境重复 8.5 的验证项

### 8.7 手动触发部署到 AAT / Prod

SIT 验证通过后，通过 `workflow_dispatch` 手动部署到 AAT，再到 Prod：

1. 进入租户仓库 → **Actions** → 选择 `TapData Deploy`
2. 点击 **Run workflow**
3. 分支选择：**Tag 名**（如 `v1.0.0`，保证部署的是同一版本）
4. **Target environment**：选择 `aat`（或 `prod`）
5. 点击 **Run workflow**
6. 经过 `deploy` 审批门 → 部署完成
7. 在对应环境重复 8.5 的验证项

> **Prod 部署建议**：确保审批人为独立的运维 / SRE 人员，不由开发自己审批；Prod `deploy` Environment 可额外开启 **Wait timer**（如 10 分钟冷却期）。

---

## 9. Rollback 流程

回滚全程 **手动触发**，用于将某个环境的资源恢复到历史 Tag 对应的版本。

### 9.1 适用场景

- 生产部署后发现配置错误或数据异常
- 需要临时还原到上一个稳定版本
- 特定环境需要单独回退（其他环境保持当前版本）

### 9.2 触发步骤

1. 进入租户仓库 → **Actions** → 选择 `TapData Rollback`
2. 点击 **Run workflow**
3. 输入参数：
   - **Target environment**：要回滚的环境（`sit` / `aat` / `prod`）
   - **Tag to rollback to**：目标 Tag（如 `v1.0.0`）
4. 点击 **Run workflow**

### 9.3 执行流程

Rollback workflow 执行 4 个 Job：

1. **preparation**：解析 Tag、获取 Token、Checkout 指定 Tag 的配置文件
2. **stop-and-unpublish**：停止当前环境所有运行中的任务、下线所有 API
3. **clean-and-reimport**：清理现有连接 / 任务 / API，从目标 Tag 重新导入
4. **report**：生成回滚报告

### 9.4 回滚后验证

登录目标环境，确认资源版本与目标 Tag 一致，任务和 API 处于未启动 / 未发布状态，手动启动并验证正常运行。

### 9.5 其他环境隔离

Rollback 只影响指定的 Target environment，其他环境不受干扰：

- 回滚 Prod 到 `v1.0.0`，Dev / SIT / AAT 仍为最新版本
- 多租户仓库互不影响（一个租户回滚不影响其他租户）

---

## 10. 常见问题

### 10.1 PR 合并后 Actions 没有触发

- 检查修改是否在 `*_tapdata_export/**` 目录下（仅此路径的变更会触发）
- 检查 `.github/workflows/tapdata-deploy.yml` 的 `on.push.paths` 配置
- 确认 PR 是否合并到了 `main` 分支

### 10.2 Worker 工作流引用失败

报错：`Could not find reusable workflow '{worker-org}/{worker-repo}/.github/workflows/tapdata-deploy.yml@main'`

- Worker 仓库可见性不是 **Internal** 或 **Public** → 改为 Internal（跨组织场景 Private 不可用）
- 租户 workflow 文件的 `{WORKER_REPO}` 占位符未替换 → 填入 `{worker-org}/{worker-repo}`
- Worker 仓库 `main` 分支没有对应工作流文件 → 推送文件
- 两个组织不在同一 GitHub Enterprise 下 → Internal 跨组织可见性依赖 Enterprise 关系，若无则需改 Public 或迁到同组织

### 10.3 Runner 排队不执行

- `sudo ./svc.sh status` 检查 Runner 服务
- 确认 Runner 的 `tapdata` 标签存在
- 确认 Runner 机器能访问 GitHub 实例

### 10.4 审批门未通知审批人

- 租户仓库 **Settings → Environments → deploy** 中确认 Required reviewers 已配置
- 审批人也可直接进入 Actions 页面手动点击 **Review deployments**

### 10.5 vault.json 生成失败 / 连接凭据错误

- GitHub Secrets 命名与 TapData 连接名称不匹配 → 按 `{ENV}_{CONNECTION}_URL` 格式检查
- 确认 Secret 设置在了正确的层级（组织级或租户仓库级）
- 如启用 `VAULT_ENCRYPTION_KEY`，确认所有下游环境都能解密

### 10.6 部署到高环境（AAT / Prod）时看不到 Tag

手动触发 workflow 时要选择 **Tag 名** 作为分支（Git ref），而不是 `main` —— 这样能保证 AAT / Prod 部署的是与 SIT 相同的版本。
