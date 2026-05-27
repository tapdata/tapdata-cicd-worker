# TapData CI/CD 交付指南

> 本文档面向 TapData 实施工程师，指导从零开始搭建多组织、多仓库 CI/CD 环境。

---

## 目录

1. [架构概览](#1-架构概览)
2. [交付文件清单](#2-交付文件清单)
3. [TapData 平台初始化](#3-tapdata-平台初始化)
4. [GitHub 环境准备](#4-github-环境准备)
5. [Worker 仓库配置](#5-worker-仓库配置)
6. [租户仓库配置](#6-租户仓库配置)
7. [Self-hosted Runner 安装](#7-self-hosted-runner-安装)
8. [验证 CI/CD 流程](#8-验证-cicd-流程)
9. [日常操作手册](#9-日常操作手册)
10. [故障排查](#10-故障排查)

---

## 1. 架构概览

### 1.1 多组织多仓库架构

本系统采用 **Worker + 租户仓库** 模式实现多租户隔离：

- `tapdata-cicd-worker`：共享部署引擎，存放所有 CI/CD 工作流和脚本，由平台运维团队维护
- `tenant-b`：Tenant B 团队的 TapData 配置仓库（连接、任务、API 的导出文件）
- `tenant-a`：Tenant A 团队的 TapData 配置仓库

租户仓库通过 `workflow_call` 调用 Worker 仓库的可复用工作流完成部署，Worker 作为共享引擎被所有租户复用。

```
GitHub Organization
├── tapdata-cicd-worker/          ← 共享部署引擎（内部可见）
│   ├── .github/workflows/
│   │   ├── tapdata-deploy.yml     ← 可复用部署工作流
│   │   └── tapdata-rollback.yml   ← 可复用回滚工作流
│   └── scripts/                   ← 部署脚本
│
├── tenant-b/               ← Tenant B 团队配置仓库
│   ├── .github/workflows/
│   │   └── tapdata-deploy.yml     ← 调用 Worker 工作流
│   └── tenant-b_tapdata_export/  ← TapData 导出文件
│
└── tenant-a/            ← Tenant A 团队配置仓库
    ├── .github/workflows/
    │   └── tapdata-deploy.yml     ← 调用 Worker 工作流
    └── tenant-a_tapdata_export/
```

### 1.2 多环境部署流程

```
TapData 本地开发（MDM Dev）
  → [导出] → GitHub PR → 合并主分支 → 自动部署 DEV
                         → 创建 Tag  → 自动部署 SIT
                         → 手动触发  → 部署 LPT
```

| 触发方式 | 目标环境 | 说明 |
|--------|---------|------|
| PR 合并到 main（自动）| DEV | 开发配置变更自动验证 |
| 创建 Git Tag（自动）| SIT | 通过 DEV 验证后提测 |
| 手动触发 workflow_dispatch | LPT / AAT / PROD | 运维手动控制高环境部署 |

### 1.3 权限隔离模型

TapData 平台通过 **用户 → 角色 → 权限** 三层模型实现多租户隔离：

- 超级管理员（admin）负责创建角色和用户
- 每个团队拥有独立角色，只能看到和操作自己的资源
- GitHub 每个租户仓库使用独立的 Secrets，凭据互相隔离

---

## 2. 交付文件清单

### 2.1 代码文件

| 文件路径 | 说明 |
|---------|------|
| `tapdata-cicd-worker/.github/workflows/tapdata-deploy.yml` | 核心部署工作流（8个 Job，含审批门） |
| `tapdata-cicd-worker/.github/workflows/tapdata-rollback.yml` | 回滚工作流（4个 Job） |
| `tapdata-cicd-worker/scripts/common/get-token.sh` | 获取 TapData 访问 Token |
| `tapdata-cicd-worker/scripts/common/compress-files.sh` | 压缩导出文件 |
| `tapdata-cicd-worker/scripts/common/preview-resource.sh` | 资源预览（dry-run） |
| `tapdata-cicd-worker/scripts/common/import-resource.sh` | 导入资源 |
| `tapdata-cicd-worker/scripts/common/stop-tasks.sh` | 停止运行中的任务 |
| `tapdata-cicd-worker/scripts/common/vault-crypto.sh` | vault.json AES-256 加解密 |
| `tapdata-cicd-worker/scripts/tapdata-deploy/generate-vault.sh` | 从 GitHub Secrets 生成 vault.json |
| `tapdata-cicd-worker/scripts/tapdata-deploy/validate-inputs.sh` | 验证部署参数 |
| `tapdata-cicd-worker/scripts/tapdata-deploy/generate-report.sh` | 生成部署汇总报告 |
| `tapdata-cicd-worker/scripts/tapdata-rollback/resolve-tag.sh` | 解析回滚目标 Tag |
| `tapdata-cicd-worker/scripts/tapdata-rollback/clean-resources.sh` | 清理现有资源 |
| `tapdata-cicd-worker/tenant-template/.github/workflows/tapdata-deploy.yml` | 租户工作流模板 |

### 2.2 文档文件

| 文件路径 | 说明 |
|---------|------|
| `tapdata-cicd-worker/docs/setup-checklist.md` | 上线前配置检查清单 |
| `tapdata-cicd-worker/docs/cicd-delivery-guide.md` | 本交付指南 |

---

## 3. TapData 平台初始化

### 3.1 创建角色与权限

以 **admin** 账号登录 TapData 平台，依次为每个租户团队创建角色。

**步骤：**

1. 进入 **系统设置** → **角色管理** → 点击 **新建角色**
2. 为 tenant-a 创建角色：

   | 字段 | 值 |
   |-----|---|
   | 角色名称 | `patient_team` |
   | 描述 | Tenant A 团队部署角色 |
   | 权限范围 | 连接 ✅、迁移任务 ✅、同步任务 ✅、API ✅ |

3. 为 tenant-b 创建角色：

   | 字段 | 值 |
   |-----|---|
   | 角色名称 | `case_team` |
   | 描述 | Tenant B 团队部署角色 |
   | 权限范围 | 连接 ✅、迁移任务 ✅、同步任务 ✅、API ✅ |

> **权限设置原则**：每个角色只能看到和操作本团队创建的资源，跨团队数据不可见。

### 3.2 创建用户并分配角色

1. 进入 **系统设置** → **用户管理** → 点击 **新建用户**
2. 创建 tenant-a 用户：

   | 字段 | 值 |
   |-----|---|
   | 用户名 | `sam`（或实际交付人员账号） |
   | 邮箱 | `sam@example.com` |
   | 角色 | `patient_team` |

3. 创建 tenant-b 用户：

   | 字段 | 值 |
   |-----|---|
   | 用户名 | `martin`（或实际交付人员账号） |
   | 邮箱 | `martin@example.com` |
   | 角色 | `case_team` |

4. 将 Access Code 提供给对应团队成员（用于 CI/CD 鉴权）

   > Access Code 在用户详情页生成，后续需配置到 GitHub Secrets（`{ENV}_TAPDATA_ACCESS_CODE`）。

### 3.3 创建连接（Connections）

以各团队账号登录后，分别创建本团队所需的数据库连接。

**以 tenant-a（sam 账号）为例：**

1. 进入 **连接管理** → 点击 **新建连接**
2. 选择数据库类型（PostgreSQL / MySQL / MongoDB 等）
3. 填写连接信息：

   | 字段 | 说明 |
   |-----|-----|
   | 连接名称 | 与 GitHub Secrets 名称保持对应，如 `HPI_SOURCE` |
   | 主机地址 | 数据库 IP/主机名 |
   | 端口 | 数据库端口 |
   | 用户名 / 密码 | 数据库凭据 |
   | 数据库名 | 目标数据库 |

4. 点击 **测试连接**，确认连接成功
5. 保存连接

> **FDM / MDM 共享连接说明**：FDM 和 MDM 是基于 MongoDB 的特殊连接，多租户共享同一 MongoDB 实例。需与 DBA 协商，按照 Collection 级或 Database 级权限隔离方案分配各团队独立的 MongoDB 凭据（详见 [多租户架构文档](../../../tapdata-github/tapdata-v35-jdk17/document/tapdata-cicd/multi-tenant-architecture.md) 第 2 节）。

**FDM / MDM 连接创建：**

```
连接名称：FDM
数据库类型：MongoDB
URI：mongodb://{用户专属账号}:{密码}@{host}:27017/fdm

连接名称：MDM
数据库类型：MongoDB
URI：mongodb://{用户专属账号}:{密码}@{host}:27017/mdm
```

### 3.4 创建迁移任务（FDM Tasks）

迁移任务负责将源库数据 1:1 同步到 FDM（MongoDB）。

1. 进入 **迁移** → 点击 **新建任务**
2. 配置任务：

   | 字段 | 说明 |
   |-----|-----|
   | 任务名称 | 建议格式：`FDM_{系统}_{表名}`，如 `FDM_HPI_cpi_patient` |
   | 源连接 | 选择源数据库连接 |
   | 目标连接 | 选择 FDM 连接 |
   | 同步模式 | 全量 + 增量（CDC） |
   | 源表 | 选择要同步的表 |
   | 目标表 | 建议与源表名保持一致 |

3. 保存任务（不需要立即启动，CI/CD 会在部署时自动启动）

### 3.5 创建同步任务（MDM Tasks）

同步任务负责从 FDM 读取数据，经过清洗转换后写入 MDM。

1. 进入 **数据转换** → 点击 **新建任务**
2. 配置任务：

   | 字段 | 说明 |
   |-----|-----|
   | 任务名称 | 建议格式：`MDM_{模型名}`，如 `MDM_cpi_patient` |
   | 源连接 | 选择 FDM 连接 |
   | 目标连接 | 选择 MDM 连接 |
   | 数据处理 | 配置字段映射、过滤、合并规则 |

3. 保存任务

### 3.6 发布 API

1. 进入 **API 服务** → 点击 **新建 API**
2. 配置 API：

   | 字段 | 说明 |
   |-----|-----|
   | API 名称 | 业务语义命名，如 `patient_query_api` |
   | 数据来源 | 选择 MDM 连接和目标集合 |
   | 接口路径 | 如 `/api/v1/patient` |
   | 访问权限 | 配置调用方鉴权方式 |

3. 保存 API（不发布，CI/CD 会在部署时自动发布）

### 3.7 创建项目并配置 GitHub 导出

1. 进入 **项目管理** → 点击 **新建项目**
2. 创建项目：

   | 字段 | 值 |
   |-----|---|
   | 项目名称 | 默认与租户仓库名保持一致，如 `tenant-a`；如需不一致，在租户仓库 Settings → Variables 设置 `PROJECT_NAME`，TapData 项目名需与该变量一致 |
   | 描述 | Tenant A 团队资源集合 |

3. 将上述连接、任务、API 添加到对应项目
4. 配置 GitHub 导出：

   | 字段 | 值 |
   |-----|---|
   | GitHub URL | 租户仓库地址，如 `https://github.example.com/org/tenant-a` |
   | GitHub Token | 有读写权限的 Personal Access Token |
   | 分支 | `main` |
   | 导出目录 | `tenant-a_tapdata_export` |

5. 点击 **导出到 GitHub**，TapData 会自动在租户仓库创建 PR

> 导出的 PR 经审批合并后，CI/CD 会自动触发部署到 DEV 环境。

---

## 4. GitHub 环境准备

### 4.1 创建 GitHub 仓库

| 仓库名 | 可见性 | 用途 |
|-------|-------|-----|
| `{org}/tapdata-cicd-worker` | **Internal**（组织内可见）| 共享部署引擎 |
| `{org}/tenant-b` | Internal 或 Private | Tenant B 团队配置仓库 |
| `{org}/tenant-a` | Internal 或 Private | Tenant A 团队配置仓库 |

> Worker 仓库必须设为 **Internal**，租户仓库才能引用其可复用工作流（`uses: org/tapdata-cicd-worker/.github/workflows/...`）。

**设置方法：**
- 进入仓库 → **Settings** → **General** → **Danger Zone** → **Change repository visibility** → 选择 **Internal**

### 4.2 配置组织级 Secrets 和 Variables

进入 GitHub 组织 → **Settings** → **Secrets and variables** → **Actions**：

**Secrets（加密，不可读取原文）：**

| 名称 | 示例值 | 说明 |
|-----|-------|-----|
| `GH_DEPLOY_TOKEN` | `ghp_xxxxxxxxxxxx` | 有读取 Worker 仓库权限的 PAT，用于 checkout 脚本 |
| `DEV_TAPDATA_ACCESS_CODE` | `xxxxxxxx-xxxx-xxxx` | DEV 环境 TapData 访问码 |
| `SIT_TAPDATA_ACCESS_CODE` | `xxxxxxxx-xxxx-xxxx` | SIT 环境 TapData 访问码 |
| `LPT_TAPDATA_ACCESS_CODE` | `xxxxxxxx-xxxx-xxxx` | LPT 环境 TapData 访问码 |
| `VAULT_ENCRYPTION_KEY` | `your-32-char-random-key` | （可选）vault.json AES-256 加密密钥，不设则明文上传 |

**Variables（明文，可读取）：**

| 名称 | 示例值 | 说明 |
|-----|-------|-----|
| `DEV_TAPDATA_URL` | `http://10.0.0.1:3030` | DEV 环境 TapData 服务地址 |
| `SIT_TAPDATA_URL` | `http://10.0.0.2:3030` | SIT 环境 TapData 服务地址 |
| `LPT_TAPDATA_URL` | `http://10.0.0.3:3030` | LPT 环境 TapData 服务地址 |

> **Access Code 获取方法**：以对应环境的 admin 账号登录 TapData → 系统设置 → 用户管理 → 点击用户名 → 复制 Access Code。

### 4.3 配置 GH_DEPLOY_TOKEN

GH_DEPLOY_TOKEN 需要是一个 **Personal Access Token（Fine-grained 或 Classic）**，权限要求：

| 权限 | 级别 | 说明 |
|-----|-----|-----|
| Contents（读） | `tapdata-cicd-worker` 仓库 | checkout 部署脚本 |
| Contents（读写） | 所有租户仓库 | TapData 导出时创建 PR |
| Pull requests（读写） | 所有租户仓库 | 创建和更新 PR |

**创建 PAT 步骤（GitHub 个人设置）：**

1. 进入 GitHub → 右上角头像 → **Settings** → **Developer settings** → **Personal access tokens**
2. 点击 **Generate new token**
3. 选择权限（如上表）
4. 生成后立即复制，配置到组织 Secrets

---

## 5. Worker 仓库配置

### 5.1 推送代码

```bash
git clone https://github.example.com/{org}/tapdata-cicd-worker.git
cd tapdata-cicd-worker
# 将 tapdata-cicd-worker 代码复制到此目录
git add .
git commit -m "feat: initial worker repo setup"
git push origin main
```

### 5.2 验证仓库可见性

确认 Worker 仓库设置为 **Internal**（组织内所有仓库可引用其工作流）：

```
仓库页面 → Settings → General → Danger Zone → Change repository visibility → Internal
```

### 5.3 无需额外配置

Worker 仓库工作流在运行时会动态获取自身的仓库地址，不需要在工作流文件中硬编码组织名。

---

## 6. 租户仓库配置

> 以下步骤以 **tenant-b** 和 **tenant-a** 为例，每新增一个租户重复执行一次。

### 6.1 添加工作流文件

在租户仓库根目录创建 `.github/workflows/tapdata-deploy.yml`：

**以 tenant-b 为例（将 `{WORKER_REPO}` 替换为实际的 Worker 仓库全名）：**

```yaml
name: TapData Deploy

on:
  push:
    branches: [main]
    paths:
      - 'tenant-b_tapdata_export/**'
    tags:
      - 'tenant-b-*'
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
    uses: {org}/tapdata-cicd-worker/.github/workflows/tapdata-deploy.yml@main
    with:
      project: tenant-b
      target_env: ${{ inputs.target_env || '' }}
      caller_repo: ${{ github.repository }}
      caller_sha: ${{ github.sha }}
      caller_event: ${{ github.event_name }}
      caller_ref: ${{ github.ref }}
      worker_repo: "{org}/tapdata-cicd-worker"
    secrets: inherit
```

**tenant-a 的工作流文件**（将所有 `tenant-b` 替换为 `tenant-a`）。

### 6.2 创建 GitHub Environments

在每个租户仓库 → **Settings** → **Environments**，创建以下环境：

| 环境名称 | Protection Rules | 说明 |
|--------|----------------|-----|
| `dev` | 无需审批 | DEV 自动部署 |
| `sit` | 无需审批 | SIT 自动部署 |
| `lpt` | 无需审批 | LPT 手动触发 |
| `deploy` | **Required reviewers：填入审批人** | 所有需审批的部署步骤使用此环境 |

> **审批门**：`deploy` 环境是核心审批节点，在部署连接配置（`deploy-connections` Job）前会暂停，等待指定审批人在 GitHub Actions 界面点击批准后继续。

### 6.3 配置数据库凭据

在租户仓库 → **Settings** → **Secrets and variables** → **Actions**：

**MongoDB 连接（URI 格式）：**

| 类型 | 名称 | 示例值 |
|-----|-----|-------|
| Secret | `DEV_FDM_URI` | `mongodb://user:pass@dev-host:27017/fdm` |
| Secret | `DEV_MDM_URI` | `mongodb://user:pass@dev-host:27017/mdm` |
| Secret | `SIT_FDM_URI` | `mongodb://user:pass@sit-host:27017/fdm` |
| Secret | `SIT_MDM_URI` | `mongodb://user:pass@sit-host:27017/mdm` |

**PostgreSQL 等其他连接（分字段格式）：**

| 类型 | 名称 | 示例值 |
|-----|-----|-------|
| Variable | `DEV_HPI_SOURCE_URL` | `10.0.1.10:5432` |
| Variable | `DEV_HPI_SOURCE_USER` | `readonly_user` |
| Secret | `DEV_HPI_SOURCE_PASSWORD` | `s3cret` |

> **命名规则**：`{ENV}_{CONNECTION_NAME}_{字段}`。`CONNECTION_NAME` 需与 TapData 中的连接名称保持一致（大写，空格替换为下划线）。

### 6.4 配置 TapData 项目

确认 TapData 平台上已存在与"解析后的项目名"同名的项目。**项目名按以下优先级解析**（自高到低）：

1. `workflow_dispatch` 手动触发时传入的 `project` 输入（单次覆盖）
2. 租户仓库 `vars.PROJECT_NAME` 变量
3. 租户仓库名

| 租户仓库 | 手动 `project` 输入 | `vars.PROJECT_NAME` | 解析后的 TapData 项目名 |
|---|---|---|---|
| `tenant-a` | _空_ | _未设置_ | `tenant-a` |
| `tenant-b` | _空_ | _未设置_ | `tenant-b` |
| `foo-cicd-config` | _空_ | `foo` | `foo` |
| `foo-cicd-config` | `bar` | `foo` | `bar` |

> 部署流程会按"解析后的项目名"查找 `{project}_tapdata_export/` 目录并匹配 TapData 项目，三者必须一致。

---

## 7. Self-hosted Runner 安装

### 7.1 系统要求

| 项目 | 要求 |
|-----|-----|
| 操作系统 | Linux（Ubuntu 20.04+ 推荐） |
| 依赖 | `git`、`bash`、`jq`、`curl`、`openssl` |
| 网络（出方向）| 可访问 GitHub 实例（HTTPS 443） |
| 网络（内网）| 可访问所有 TapData 服务器（对应端口） |

### 7.2 安装步骤

**在 Runner 服务器上执行：**

```bash
# 1. 安装依赖
sudo apt-get update
sudo apt-get install -y git jq curl openssl

# 2. 创建运行目录
mkdir -p /opt/github-runner && cd /opt/github-runner

# 3. 下载 Runner 程序（从 GitHub 组织 Settings 页面获取最新版本链接）
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.example.com/{org}/actions-runner/releases/download/v2.x.x/actions-runner-linux-x64-2.x.x.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# 4. 配置 Runner（从 GitHub 组织 Settings 页面获取注册 Token）
./config.sh \
  --url https://github.example.com/{org} \
  --token {REGISTRATION_TOKEN} \
  --name "tapdata-runner-01" \
  --labels "tapdata" \
  --unattended

# 5. 注册为 systemd 服务并启动
sudo ./svc.sh install
sudo ./svc.sh start
```

> **注册 Token 获取**：GitHub 组织 → **Settings** → **Actions** → **Runners** → **New self-hosted runner**，页面上会显示注册命令和 Token。

### 7.3 验证 Runner 状态

1. 进入 GitHub 组织 → **Settings** → **Actions** → **Runners**
2. 确认 Runner 显示 **Idle** 状态
3. 确认 Runner 标签包含 `tapdata`

### 7.4 自定义 Label 说明

工作流中通过 `runs-on: [self-hosted, tapdata]` 指定 Runner，`tapdata` 是自定义标签，确保部署任务只在有网络权限访问 TapData 服务器的机器上运行。

---

## 8. 验证 CI/CD 流程

### 8.1 端到端验证步骤

#### Step 1：验证 Worker 仓库可达性

在租户仓库中创建一个简单的测试提交，观察 Actions 是否能正常调用 Worker 工作流：

```bash
# 在 tenant-b 仓库
git checkout -b test/cicd-verify
echo "# test" >> README.md
git add README.md
git commit -m "test: verify cicd connectivity"
git push origin test/cicd-verify
# 创建 PR → 合并到 main → 观察 Actions 是否触发
```

#### Step 2：验证 DEV 部署

1. 以 `martin`（tenant-b）账号登录 TapData **本地开发环境**
2. 确认连接、任务、API 均已创建并配置到 `tenant-b` 项目
3. 点击 **导出到 GitHub**，TapData 自动在 `tenant-b` 仓库创建 PR
4. 审批并合并 PR
5. 进入 GitHub → **Actions** → 确认 `TapData Deploy` 工作流已触发
6. 工作流运行到 `deploy-connections` Job 时，会等待 `deploy` 环境审批
7. 在 GitHub Actions 页面点击 **Review deployments** → 选择 `deploy` → **Approve and deploy**
8. 工作流继续执行，完成全部部署步骤
9. 以 `martin` 账号登录 TapData **DEV 环境**，验证：
   - 连接已导入且测试通过
   - 迁移任务、同步任务已导入（状态为"未启动"）
   - API 已创建（未发布状态）
10. 手动启动任务、发布 API，确认运行正常

#### Step 3：验证 SIT 部署

```bash
# 在 tenant-b 仓库创建 Tag
git tag tenant-b-v1.0.0
git push origin tenant-b-v1.0.0
# → Actions 自动触发并部署到 SIT 环境
```

#### Step 4：验证租户隔离

- 以 `sam`（tenant-a）账号登录 TapData DEV，确认看不到 tenant-b 的任何资源
- 以 `martin`（tenant-b）账号登录，确认看不到 tenant-a 的任何资源

### 8.2 常见验证检查点

| 检查点 | 预期结果 |
|-------|---------|
| Actions 触发 | PR 合并后 30 秒内出现 workflow run |
| Runner 选中 | workflow run 中显示使用了 `tapdata` label 的 Runner |
| Secrets 解析 | `preparation` Job 日志中 vault.json 生成成功，无报错 |
| 审批门 | `deploy-connections` Job 进入 Waiting 状态等待审批 |
| 连接导入 | TapData 中连接状态为"已连接" |
| 任务导入 | TapData 中任务状态为"未启动" |
| 部署报告 | Actions 最后一步 `report` Job 生成 Job Summary |

---

## 9. 日常操作手册

### 9.1 更新配置并重新部署

**场景**：TapData 中修改了连接或任务配置，需要同步到 DEV。

```
1. 登录 TapData 本地开发环境，修改对应连接/任务/API
2. 进入项目管理，点击 "导出到 GitHub"
3. TapData 自动在租户仓库创建 PR（更新 export 目录中的 JSON 文件）
4. 审批人 Review PR → 合并到 main
5. Actions 自动触发 → 部署到 DEV
```

### 9.2 部署到 SIT

```bash
# DEV 验证通过后，在租户仓库创建版本 Tag
git tag {project}-v{版本号}
git push origin {project}-v{版本号}
# 示例：
git tag tenant-b-v1.2.0
git push origin tenant-b-v1.2.0
```

> Tag 创建后，Actions 自动触发并部署到 SIT 环境，同样需要通过 `deploy` 环境的审批门。

### 9.3 手动部署到 LPT

1. 进入租户仓库 → **Actions** → 选择 `TapData Deploy`
2. 点击 **Run workflow**
3. 选择分支：`main`
4. 选择 Target environment：`lpt`
5. 点击 **Run workflow**
6. 在审批节点点击批准

### 9.4 回滚操作

**场景**：SIT 环境发现 tenant-b 配置有问题，需要回滚到上一个版本。

1. 进入 `tenant-b` 仓库 → **Actions** → 选择 `TapData Rollback`（如有）
2. 或手动触发工作流，指定回滚目标 Tag（如 `tenant-b-v1.1.0`）
3. 工作流会执行：停止任务 → 清理资源 → 从目标版本重新导入 → 重新激活
4. 仅 tenant-b 的资源受影响，tenant-a 完全不受干扰

### 9.5 新增租户

每新增一个团队，执行以下步骤：

1. 在 TapData 中创建新角色 + 用户（见 [第 3.1-3.2 节](#31-创建角色与权限)）
2. 在 GitHub 中创建新租户仓库（见 [第 4.1 节](#41-创建-github-仓库)）
3. 为新仓库创建工作流文件（见 [第 6.1 节](#61-添加工作流文件)）
4. 创建 GitHub Environments（见 [第 6.2 节](#62-创建-github-environments)）
5. 配置数据库凭据（见 [第 6.3 节](#63-配置数据库凭据)）
6. 创建 TapData 项目（见 [第 6.4 节](#64-配置-tapdata-项目)）

---

## 10. 故障排查

### 10.1 常见问题

**问题：Actions 触发后提示无法访问 Worker 仓库的工作流**

```
Error: Could not find reusable workflow
'{org}/tapdata-cicd-worker/.github/workflows/tapdata-deploy.yml@main'
```

原因和解决方法：
- Worker 仓库可见性不是 **Internal** → 修改为 Internal
- `{WORKER_REPO}` 占位符未替换 → 检查租户工作流文件中的 `uses` 字段
- Worker 仓库 `main` 分支不存在工作流文件 → 确认文件已推送

---

**问题：`preparation` Job 报错 vault.json 生成失败**

```
Error: generate-vault.sh: CONNECTION_NAME secret not found
```

原因和解决方法：
- GitHub Secrets 命名与 TapData 连接名称不匹配 → 检查 `{ENV}_{CONNECTION_NAME}_URL` 格式
- Secret 配置在了错误的层级（应在组织级或仓库级）→ 检查 Secret 所在位置

---

**问题：Runner 一直处于 Queued 状态，不执行**

原因和解决方法：
- Runner 未启动 → 在 Runner 机器上执行 `sudo ./svc.sh status`，确认服务运行
- Runner 标签不匹配 → 确认 Runner 有 `tapdata` 标签，工作流 `runs-on` 配置正确
- Runner 网络不通 → 确认 Runner 可以访问 GitHub 实例（`curl https://github.example.com`）

---

**问题：`deploy-connections` Job 一直等待审批，但没有审批人收到通知**

原因和解决方法：
- `deploy` Environment 未配置 Required reviewers → 进入租户仓库 Settings → Environments → deploy → 添加审批人
- 审批人没有收到邮件通知 → 检查 GitHub 通知设置；审批人也可直接进入 Actions 页面手动操作

---

**问题：TapData 中连接导入成功但测试失败**

原因和解决方法：
- vault.json 中的凭据有误 → 检查对应的 GitHub Secrets 值是否正确
- 网络不通 → 确认 TapData 服务器可以访问目标数据库的 IP 和端口
- FDM/MDM MongoDB 用户权限不足 → 联系 DBA 确认 MongoDB 用户的 Collection 级权限已正确配置

### 10.2 日志查看

| 日志位置 | 说明 |
|--------|-----|
| GitHub Actions Job 日志 | 每个步骤的详细输出，含脚本执行日志 |
| GitHub Actions Job Summary | 部署完成后的汇总报告（资源统计、环境信息）|
| TapData 任务日志 | TapData 平台 → 任务详情 → 日志 tab |
| Runner 本地日志 | `/opt/github-runner/_diag/` 目录 |

### 10.3 紧急回滚

如遇紧急情况需立即回滚，可在 TapData 平台直接操作（无需 CI/CD）：

1. 登录对应环境的 TapData
2. 手动停止问题任务
3. 删除问题连接/任务/API
4. 从上一个备份版本手动导入配置文件（位于租户仓库对应 Tag 的 export 目录）

> 手动操作后，TapData 平台状态与 GitHub 代码会出现偏差，需在下次 CI/CD 部署时通过完整部署流程重新同步。
