#!/usr/bin/env bash
set -euo pipefail

# 检测 PROJECT 参数
# 约定：一个仓库只放一个项目（one repo, one project）。
# 输入环境变量：INPUT_PROJECT(可空), REPO_ROOT, GITHUB_REPOSITORY,
#               PROJECT_NAME(可选), GITHUB_OUTPUT, GITHUB_ENV
# 逻辑：
#   - INPUT_PROJECT 非空（workflow_call 由租户程序化传入）→ 直接使用
#   - 否则自动检测仓库根下的 *_tapdata_export/ 目录：
#       * 恰好 1 个 → 用它（一仓一项目，无需对比仓库名）
#       * 多个(不推荐) → 优先 vars.PROJECT_NAME / 仓库名命中的，否则取第一个，并告警
#   - 检测不到任何目录 → 报错退出（避免静默使用错误的项目名）

PROJECT="${INPUT_PROJECT:-}"

if [[ -z "${PROJECT}" ]]; then
  mapfile -t PROJECTS < <(
    find "${REPO_ROOT:-.}" -maxdepth 2 -type d -name '*_tapdata_export' 2>/dev/null \
      | sed 's#_tapdata_export$##; s#.*/##' | sort -u
  )
  if (( ${#PROJECTS[@]} == 0 )); then
    echo "::error::No *_tapdata_export/ directory found under ${REPO_ROOT:-.}." >&2
    exit 1
  elif (( ${#PROJECTS[@]} == 1 )); then
    PROJECT="${PROJECTS[0]}"
  else
    PREFERRED="${PROJECT_NAME:-${GITHUB_REPOSITORY##*/}}"
    if printf '%s\n' "${PROJECTS[@]}" | grep -qx "${PREFERRED}"; then
      PROJECT="${PREFERRED}"
    else
      PROJECT="${PROJECTS[0]}"
    fi
    echo "::warning::Multiple projects found (${PROJECTS[*]}); deploying '${PROJECT}'. Convention is one project per repo."
  fi
fi

echo "Detected PROJECT: $PROJECT"
echo "project=$PROJECT" >> "$GITHUB_OUTPUT"
echo "PROJECT=$PROJECT" >> "$GITHUB_ENV"
