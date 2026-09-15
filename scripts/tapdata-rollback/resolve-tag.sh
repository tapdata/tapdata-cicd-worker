#!/usr/bin/env bash
# Validate that the provided rollback tag exists in the data repository.
#
# 单仓库/多租户两种模式行为完全一致：都在 Job 1 已经 checkout 好的数据仓库工作区里
# 用 git 校验，不调 GitHub REST API —— 与 deploy 保持同一套仓库访问方式
# （只走 actions/checkout 建立起来的 git 传输），因此在 github.com 和客户私有化
# GHES 上行为相同、无需任何额外网络放通或 token 权限。
#
# 历史教训：这里曾把 https://api.github.com 硬编码为多租户模式的校验入口，
# 在内网 GHES 的 self-hosted runner 上必然解析失败（curl exit 6 = could not
# resolve host），且因为 `set -e` 直接带着 curl 的原始退出码死掉，脚本自己的
# ::error:: 分支根本来不及打印。
#
# 为什么这一步不能省掉、交给 Job 3 的 checkout 去验：
# Job 2 (stop-and-clean) 会真的停线上任务、下线 API、清资源。tag 必须在动手
# 破坏之前验掉，否则就变成"停完了才发现 tag 不存在、回不去"。
#
# Required env vars: LAST_STABLE_TAG
# Optional env vars: REPO_ROOT（数据仓库 checkout 根目录，缺省为当前目录）
# Output: last_stable_tag (via GITHUB_OUTPUT)
set -euo pipefail

echo "=== Validating Rollback Tag ==="

if [[ -z "${LAST_STABLE_TAG:-}" ]]; then
  echo "::error::LAST_STABLE_TAG is not set or empty. A rollback tag must be provided."
  exit 1
fi

REPO_DIR="${REPO_ROOT:-$PWD}"

if ! git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "::error::'${REPO_DIR}' is not a git work tree; cannot validate tag '${LAST_STABLE_TAG}'."
  exit 1
fi

echo "Validating tag '${LAST_STABLE_TAG}' in the checked-out data repository at '${REPO_DIR}'..."

if git -C "${REPO_DIR}" rev-parse --verify --quiet "refs/tags/${LAST_STABLE_TAG}" >/dev/null; then
  echo "Tag '${LAST_STABLE_TAG}' exists, using it for rollback."
else
  # 本地没有不等于远端没有：数据仓库的 checkout 一旦被改成浅克隆 / 不带 tags，
  # 本地就查不到。回远端确认一次，把"这个 tag 真不存在"和"只是没 fetch 下来"
  # 分开——否则后者会伪装成前者，报出一个误导性的"tag 不存在"。
  # 用的是 actions/checkout 已经配好并且刚刚用过的那条 origin 传输（GHES 上即 GHES 自身）。
  echo "Tag '${LAST_STABLE_TAG}' not found locally, confirming against 'origin'..."

  if ! REMOTE_REF="$(git -C "${REPO_DIR}" ls-remote --tags origin "refs/tags/${LAST_STABLE_TAG}" 2>&1)"; then
    echo "::error::Failed to reach 'origin' while confirming tag '${LAST_STABLE_TAG}': ${REMOTE_REF}"
    exit 1
  fi

  if [[ -z "${REMOTE_REF}" ]]; then
    echo "::error::Tag '${LAST_STABLE_TAG}' does not exist in the data repository."
    exit 1
  fi

  echo "::warning::Tag '${LAST_STABLE_TAG}' exists on 'origin' but was not present locally — the data repository checkout did not include tags (check fetch-depth)."
fi

echo "last_stable_tag=${LAST_STABLE_TAG}" >> "${GITHUB_OUTPUT}"
echo "=== Tag Validation Complete ==="
