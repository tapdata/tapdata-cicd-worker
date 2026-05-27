#!/usr/bin/env bash
# Restore task attrs, start tasks defined in export directory, and publish previously-active APIs after rollback
# Required env vars: TAPDATA_TOKEN, TAPDATA_URL, PROJECT
# Optional env vars: STOPPED_TASKS_FILE (JSON with id, name, attrs, status)
#                    UNPUBLISHED_APIS_FILE (JSON with id, status, tableName)
set -euo pipefail

echo "=== Starting Tasks and Publishing APIs ==="

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
TASK_EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export/Task"

# ── Step 1: Restore task attrs ──
echo ""
echo "────────────────────────────────────────"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 1: Restore task attrs"
echo "────────────────────────────────────────"

if [[ -n "${STOPPED_TASKS_FILE:-}" && -f "${STOPPED_TASKS_FILE}" ]]; then
  TASK_COUNT=$(jq 'length' "${STOPPED_TASKS_FILE}")
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restoring attrs for ${TASK_COUNT} task(s)..."

  while IFS= read -r item; do
    TASK_ID=$(echo "${item}" | jq -r '.id')
    TASK_NAME=$(echo "${item}" | jq -r '.name // "unknown"')
    ATTRS=$(echo "${item}" | jq -c '.attrs')

    PATCH_URL="${API_BASE}/task/${TASK_ID}?access_token=${TAPDATA_TOKEN}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updating attrs for task: ${TASK_NAME} (id: ${TASK_ID})..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Request URL: PATCH ${PATCH_URL}"

    PAYLOAD=$(jq -n -c --argjson attrs "${ATTRS}" '{attrs: $attrs}')

    RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${PATCH_URL}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")

    HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
    BODY=$(echo "${RESPONSE}" | sed '$d')

    if [[ "${HTTP_CODE}" -ne 200 ]]; then
      echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to update attrs for task '${TASK_NAME}' (id: ${TASK_ID}): HTTP ${HTTP_CODE} - ${BODY}"
      exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task '${TASK_NAME}' (id: ${TASK_ID}) attrs updated successfully ✓"
  done < <(jq -c '.[]' "${STOPPED_TASKS_FILE}")

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] All task attrs restored successfully ✓"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No stopped tasks file provided or file not found, skipping attrs restore"
fi

# ── Step 2: Start tasks defined in export directory ──
echo ""
echo "────────────────────────────────────────"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 2: Start tasks from export directory"
echo "────────────────────────────────────────"

if [[ ! -d "${TASK_EXPORT_DIR}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Task export directory not found: ${TASK_EXPORT_DIR}, skipping task start"
elif [[ -z "${STOPPED_TASKS_FILE:-}" || ! -f "${STOPPED_TASKS_FILE}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No stopped tasks file provided or file not found, skipping task start"
else
  # Collect task names from *Task.json files in export directory
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Scanning task export directory: ${TASK_EXPORT_DIR}"
  TASK_NAMES=()
  for task_file in "${TASK_EXPORT_DIR}"/*Task.json; do
    if [[ ! -f "${task_file}" ]]; then continue; fi
    TASK_NAME=$(jq -r '.[0].json.name // empty' "${task_file}" 2>/dev/null)
    if [[ -n "${TASK_NAME}" ]]; then
      TASK_NAMES+=("${TASK_NAME}")
      echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Found task: ${TASK_NAME} (from $(basename "${task_file}"))"
    fi
  done

  if [[ ${#TASK_NAMES[@]} -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No task definitions found in export directory, skipping task start"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Found ${#TASK_NAMES[@]} task(s) in export directory"

    # Look up task IDs from stopped tasks file by name, only start previously-running tasks
    TASK_IDS_PARAMS=""
    START_COUNT=0
    SKIP_COUNT=0
    for tname in "${TASK_NAMES[@]}"; do
      TASK_RECORD=$(jq -c --arg name "${tname}" '.[] | select(.name == $name)' "${STOPPED_TASKS_FILE}")
      if [[ -z "${TASK_RECORD}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   WARNING: Task '${tname}' not found in stopped tasks file, skipping"
        continue
      fi

      TASK_ID=$(echo "${TASK_RECORD}" | jq -r '.id')
      PREV_STATUS=$(echo "${TASK_RECORD}" | jq -r '.status')

      if [[ "${PREV_STATUS}" == "running" ]]; then
        START_COUNT=$((START_COUNT + 1))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Matched: ${tname} → id: ${TASK_ID} (previous status: ${PREV_STATUS}, will start)"
        if [[ -n "${TASK_IDS_PARAMS}" ]]; then
          TASK_IDS_PARAMS="${TASK_IDS_PARAMS}&taskIds=${TASK_ID}"
        else
          TASK_IDS_PARAMS="taskIds=${TASK_ID}"
        fi
      else
        SKIP_COUNT=$((SKIP_COUNT + 1))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Matched: ${tname} → id: ${TASK_ID} (previous status: ${PREV_STATUS}, skip start)"
      fi
    done

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Summary: ${START_COUNT} task(s) to start, ${SKIP_COUNT} task(s) skipped (not previously running)"

    if [[ "${START_COUNT}" -eq 0 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] No previously-running tasks to start, skipping batch start"
    else
      START_URL="${API_BASE}/task/batchStart?access_token=${TAPDATA_TOKEN}&${TASK_IDS_PARAMS}"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting ${START_COUNT} task(s)..."
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Request URL: PUT ${START_URL}"

      RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${START_URL}")
      HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
      BODY=$(echo "${RESPONSE}" | sed '$d')

      if [[ "${HTTP_CODE}" -ne 200 ]]; then
        echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to batch start tasks: HTTP ${HTTP_CODE} - ${BODY}"
        exit 1
      fi

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] All ${START_COUNT} task(s) started successfully ✓"
    fi
  fi
fi

# ── Step 3: Publish previously-active APIs ──
echo ""
echo "────────────────────────────────────────"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 3: Publish previously-active APIs"
echo "────────────────────────────────────────"

if [[ -n "${UNPUBLISHED_APIS_FILE:-}" && -f "${UNPUBLISHED_APIS_FILE}" ]]; then
  ACTIVE_APIS=$(jq -c '[.[] | select(.status == "active")]' "${UNPUBLISHED_APIS_FILE}")
  ACTIVE_COUNT=$(echo "${ACTIVE_APIS}" | jq 'length')

  if [[ "${ACTIVE_COUNT}" -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No previously-active APIs found, skipping publish"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Publishing ${ACTIVE_COUNT} previously-active API(s)..."
    PATCH_URL="${API_BASE}/Modules/batchUpdate?access_token=${TAPDATA_TOKEN}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] APIs to publish:"
    echo "${ACTIVE_APIS}" | jq -r '.[] | "  - \(.tableName) (id: \(.id))"'
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Request URL: PATCH ${PATCH_URL}"

    PAYLOAD=$(echo "${ACTIVE_APIS}" | jq -c '[.[] | {id, status: "active", tableName}]')

    RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH "${PATCH_URL}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")

    HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
    BODY=$(echo "${RESPONSE}" | sed '$d')

    if [[ "${HTTP_CODE}" -ne 200 ]]; then
      echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to publish APIs: HTTP ${HTTP_CODE} - ${BODY}"
      exit 1
    fi

    RESP_CODE=$(echo "${BODY}" | jq -r '.code // empty')
    if [[ -n "${RESP_CODE}" && "${RESP_CODE}" != "ok" ]]; then
      echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to publish APIs: response code '${RESP_CODE}' - ${BODY}"
      exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] All ${ACTIVE_COUNT} API(s) published successfully ✓"
  fi
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No unpublished APIs file provided or file not found, skipping API publish"
fi

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Start and Publish Complete ==="

