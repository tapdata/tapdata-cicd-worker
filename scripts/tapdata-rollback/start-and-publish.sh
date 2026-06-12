#!/usr/bin/env bash
# 回滚导入后：校验资源确已落地，再把本项目的任务启动、API 发布。
#
# 为什么重写（修复 B + C）：
#   旧版用 STOPPED_TASKS_FILE / UNPUBLISHED_APIS_FILE 里【删除前】的旧 id 去 PATCH/start/publish。
#   但这些资源在 clean 阶段已被删除、import 阶段又重建，旧 id 可能失效；TapData 对失效 id 仍返回
#   200，于是静默空操作 —— 任务停着不跑、API 不发布，且没有任何报错。跨 Job 的 /tmp 文件在多
#   runner 下还可能根本不存在。
#
#   新版改为按本项目【导出里定义的资源名】去线上重新查【当前 id】，再启动 / 发布：
#     - B（落地校验）：导出里定义的每个任务 / API，若在 IMPORT_VERIFY_TIMEOUT 内没在线上出现，
#       直接报错退出。把"导入报成功但其实没落地"从静默失败变成显式失败。
#     - C（可靠激活）：用查到的当前 id 启动所有非 running 任务、把所有 API 置为 active。
#
# Required env vars: TAPDATA_TOKEN, TAPDATA_URL, PROJECT
# Optional env vars: REPO_ROOT, IMPORT_VERIFY_TIMEOUT (默认 120s), POLL_INTERVAL (默认 5s)
set -euo pipefail

echo "=== Reactivating Tasks & APIs (verify import landed → start → publish) ==="

if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi
if [[ -z "${PROJECT:-}" ]]; then
  echo "::error::PROJECT is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"
API_BASE="${BASE_URL%/}/api"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export"
TASK_EXPORT_DIR="${EXPORT_DIR}/Task"
API_EXPORT_DIR="${EXPORT_DIR}/API"
VERIFY_TIMEOUT="${IMPORT_VERIFY_TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

urlencode() {
  python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# 扫描导出目录下的 *<suffix> 文件，逐行输出 .[0].json.name
collect_names() {
  local dir="$1" suffix="$2" f name
  [[ -d "${dir}" ]] || return 0
  for f in "${dir}"/*"${suffix}"; do
    [[ -f "${f}" ]] || continue
    name=$(jq -r '.[0].json.name // empty' "${f}" 2>/dev/null || true)
    [[ -n "${name}" ]] && printf '%s\n' "${name}"
  done
}

# 轮询线上资源，直到导出里定义的每个名字都出现，或超时报错。
# $1 = 资源接口（Task | Modules），$2 = JSON 数组（期望的名字），$3..= 额外 fields（jq 片段）
# 成功后把最终一次查询的响应 body 写入全局变量 VERIFY_BODY
VERIFY_BODY=""
verify_landed() {
  local endpoint="$1" expected_inq="$2" extra_fields="$3"
  local elapsed=0 filter url resp code body found missing
  while true; do
    filter=$(jq -n -c --argjson inq "${expected_inq}" --argjson ef "${extra_fields}" \
      '{fields: ({id:true,name:true} + $ef), where: {name: {"$inq": $inq}}}')
    url="${API_BASE}/${endpoint}?access_token=${TAPDATA_TOKEN}&filter=$(urlencode "${filter}")"
    resp=$(curl -s -w "\n%{http_code}" -X GET "${url}")
    code=$(tail -n1 <<<"${resp}")
    body=$(sed '$d' <<<"${resp}")
    if [[ "${code}" -ne 200 ]]; then
      echo "::error::[$(ts)] Failed to query ${endpoint}: HTTP ${code} - ${body}"
      exit 1
    fi
    found=$(jq -c '[.data.items[].name]' <<<"${body}")
    missing=$(jq -rn --argjson exp "${expected_inq}" --argjson found "${found}" '($exp - $found) | .[]')
    if [[ -z "${missing}" ]]; then
      VERIFY_BODY="${body}"
      return 0
    fi
    if [[ ${elapsed} -ge ${VERIFY_TIMEOUT} ]]; then
      echo "::error::[$(ts)] Import landing check FAILED: 导出里定义的以下 ${endpoint} 在 ${VERIFY_TIMEOUT}s 内始终没在线上出现（导入未真正落地）："
      echo "${missing}" | sed 's/^/  - /'
      exit 1
    fi
    echo "[$(ts)] 等待导入落地中（elapsed ${elapsed}s/${VERIFY_TIMEOUT}s），尚未出现：$(echo "${missing}" | paste -sd, -)"
    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}

# ── Step 1: 任务 —— 校验落地，然后启动所有非 running 任务 ──
echo ""
echo "────────────────────────────────────────"
echo "[$(ts)] Step 1: 校验任务落地并启动"
echo "────────────────────────────────────────"

mapfile -t TASK_NAMES < <(collect_names "${TASK_EXPORT_DIR}" "Task.json")

if [[ ${#TASK_NAMES[@]} -eq 0 ]]; then
  echo "[$(ts)] 导出里没有任务定义（${TASK_EXPORT_DIR}），跳过任务激活"
else
  echo "[$(ts)] 导出里定义了 ${#TASK_NAMES[@]} 个任务：${TASK_NAMES[*]}"
  TASK_INQ=$(printf '%s\n' "${TASK_NAMES[@]}" | jq -R . | jq -s -c .)

  echo "[$(ts)] 校验这些任务是否已导入落地..."
  verify_landed "Task" "${TASK_INQ}" '{"status":true}'
  echo "[$(ts)] 所有任务均已在线上出现 ✓"

  # 当前状态
  echo "[$(ts)] 当前任务状态："
  echo "${VERIFY_BODY}" | jq -r '.data.items[] | "  - \(.name) (id: \(.id)): \(.status)"'

  # 启动所有非 running 任务
  START_IDS=$(echo "${VERIFY_BODY}" | jq -r '.data.items[] | select(.status != "running") | .id')
  START_COUNT=$(echo "${VERIFY_BODY}" | jq '[.data.items[] | select(.status != "running")] | length')

  if [[ "${START_COUNT}" -eq 0 ]]; then
    echo "[$(ts)] 所有任务已是 running 状态，无需启动"
  else
    TASK_IDS_PARAMS=""
    while IFS= read -r tid; do
      [[ -z "${tid}" ]] && continue
      if [[ -n "${TASK_IDS_PARAMS}" ]]; then
        TASK_IDS_PARAMS="${TASK_IDS_PARAMS}&taskIds=${tid}"
      else
        TASK_IDS_PARAMS="taskIds=${tid}"
      fi
    done <<< "${START_IDS}"

    START_URL="${API_BASE}/task/batchStart?access_token=${TAPDATA_TOKEN}&${TASK_IDS_PARAMS}"
    echo "[$(ts)] 启动 ${START_COUNT} 个任务..."
    echo "[$(ts)] Request URL: PUT ${API_BASE}/task/batchStart (${TASK_IDS_PARAMS})"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${START_URL}")
    HTTP_CODE=$(tail -n1 <<<"${RESPONSE}")
    BODY=$(sed '$d' <<<"${RESPONSE}")
    if [[ "${HTTP_CODE}" -ne 200 ]]; then
      echo "::error::[$(ts)] 批量启动任务失败: HTTP ${HTTP_CODE} - ${BODY}"
      exit 1
    fi
    echo "[$(ts)] ${START_COUNT} 个任务已下发启动 ✓"
  fi
fi

# ── Step 2: API —— 校验落地，然后全部发布为 active ──
echo ""
echo "────────────────────────────────────────"
echo "[$(ts)] Step 2: 校验 API 落地并发布"
echo "────────────────────────────────────────"

mapfile -t API_NAMES < <(collect_names "${API_EXPORT_DIR}" "Module.json")

if [[ ${#API_NAMES[@]} -eq 0 ]]; then
  echo "[$(ts)] 导出里没有 API 定义（${API_EXPORT_DIR}），跳过 API 发布"
else
  echo "[$(ts)] 导出里定义了 ${#API_NAMES[@]} 个 API：${API_NAMES[*]}"
  API_INQ=$(printf '%s\n' "${API_NAMES[@]}" | jq -R . | jq -s -c .)

  echo "[$(ts)] 校验这些 API 是否已导入落地..."
  verify_landed "Modules" "${API_INQ}" '{"tableName":true,"status":true}'
  echo "[$(ts)] 所有 API 均已在线上出现 ✓"

  echo "[$(ts)] 当前 API 状态："
  echo "${VERIFY_BODY}" | jq -r '.data.items[] | "  - \(.name) / \(.tableName) (id: \(.id)): \(.status)"'

  # 全部置为 active
  PAYLOAD=$(echo "${VERIFY_BODY}" | jq -c '[.data.items[] | {id, status: "active", tableName}]')
  PATCH_URL="${API_BASE}/Modules/batchUpdate?access_token=${TAPDATA_TOKEN}"
  echo "[$(ts)] 发布 ${#API_NAMES[@]} 个 API（status=active）..."
  echo "[$(ts)] Request URL: PATCH ${PATCH_URL}"

  RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${PATCH_URL}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")
  HTTP_CODE=$(tail -n1 <<<"${RESPONSE}")
  BODY=$(sed '$d' <<<"${RESPONSE}")
  if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo "::error::[$(ts)] 批量发布 API 失败: HTTP ${HTTP_CODE} - ${BODY}"
    exit 1
  fi
  RESP_CODE=$(jq -r '.code // empty' <<<"${BODY}")
  if [[ -n "${RESP_CODE}" && "${RESP_CODE}" != "ok" ]]; then
    echo "::error::[$(ts)] 批量发布 API 失败: response code '${RESP_CODE}' - ${BODY}"
    exit 1
  fi
  echo "[$(ts)] ${#API_NAMES[@]} 个 API 已发布 ✓"
fi

echo ""
echo "[$(ts)] === Reactivation Complete ==="
