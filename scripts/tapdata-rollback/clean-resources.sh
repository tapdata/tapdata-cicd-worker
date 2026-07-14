#!/usr/bin/env bash
# Clean TapData resources (APIs, tasks) for rollback
# 1. Delete each API via DELETE /api/Modules/{id}
# 2. Poll stopped tasks and progressively batch delete via DELETE /api/Task/batchDelete
# Required env vars: TAPDATA_TOKEN, TAPDATA_URL
# Optional env vars: STOPPED_TASKS_FILE (path to JSON file with task id/attrs/status), API_IDS (comma separated)
set -euo pipefail

echo "=== Cleaning Resources ==="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting resource cleanup..."

if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"
API_BASE="${BASE_URL%/}/api"

# ── Step 1: Delete APIs one by one ──
echo ""
echo "────────────────────────────────────────"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 1: Delete APIs"
echo "────────────────────────────────────────"

if [[ -n "${API_IDS:-}" ]]; then
  IFS=',' read -ra AID_ARRAY <<< "${API_IDS}"
  API_TOTAL=${#AID_ARRAY[@]}
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Found ${API_TOTAL} API(s) to delete"

  API_INDEX=0
  for aid in "${AID_ARRAY[@]}"; do
    aid=$(echo "${aid}" | xargs)
    if [[ -z "${aid}" ]]; then
      continue
    fi

    API_INDEX=$((API_INDEX + 1))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${API_INDEX}/${API_TOTAL}] Deleting API: ${aid}..."
    DELETE_API_URL="${API_BASE}/Modules/${aid}?access_token=${TAPDATA_TOKEN}"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${DELETE_API_URL}")
    HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
    BODY=$(echo "${RESPONSE}" | sed '$d')

    if [[ "${HTTP_CODE}" -ne 200 ]]; then
      echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to delete API '${aid}': HTTP ${HTTP_CODE} - ${BODY}"
      exit 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${API_INDEX}/${API_TOTAL}] API '${aid}' deleted successfully ✓"
  done

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] All ${API_TOTAL} API(s) deleted successfully ✓"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No API IDs provided, skipping API deletion"
fi

# ── Step 2: Progressively delete tasks as they reach "stop" status ──
echo ""
echo "────────────────────────────────────────"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Step 2: Delete Tasks (wait for stop → delete)"
echo "────────────────────────────────────────"

TASK_DELETE_TIMEOUT=600
POLL_INTERVAL=${POLL_INTERVAL:-5}

if [[ -n "${STOPPED_TASKS_FILE:-}" && -f "${STOPPED_TASKS_FILE}" ]]; then
  TASK_COUNT=$(jq 'length' "${STOPPED_TASKS_FILE}")

  if [[ "${TASK_COUNT}" -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No tasks in stopped tasks file, skipping task deletion"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total ${TASK_COUNT} task(s) to delete:"
    jq -r '.[] | "  - \(.name) (id: \(.id), status: \(.status))"' "${STOPPED_TASKS_FILE}"

    # Build the pending list with id and name
    PENDING_IDS_FILE="/tmp/pending-task-ids-${GITHUB_RUN_ID:-$$}.json"
    jq '[.[] | {id, name}]' "${STOPPED_TASKS_FILE}" > "${PENDING_IDS_FILE}"
    DELETED_COUNT=0
    ELAPSED=0
    ROUND=0

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting progressive deletion loop (timeout: ${TASK_DELETE_TIMEOUT}s, poll interval: ${POLL_INTERVAL}s)..."

    while true; do
      REMAINING=$(jq 'length' "${PENDING_IDS_FILE}")
      if [[ "${REMAINING}" -eq 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] All ${TASK_COUNT} task(s) have been deleted successfully ✓"
        break
      fi

      if [[ ${ELAPSED} -ge ${TASK_DELETE_TIMEOUT} ]]; then
        echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Timed out after ${TASK_DELETE_TIMEOUT}s. ${REMAINING} task(s) still not deletable:"
        jq -r '.[] | "  - \(.name) (id: \(.id))"' "${PENDING_IDS_FILE}"
        rm -f "${PENDING_IDS_FILE}"
        exit 1
      fi

      ROUND=$((ROUND + 1))
      echo ""
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ── Round ${ROUND} (elapsed: ${ELAPSED}s/${TASK_DELETE_TIMEOUT}s, remaining: ${REMAINING}/${TASK_COUNT}) ──"

      # Query current status for all pending tasks
      INQ_ARRAY=$(jq -c '[.[].id]' "${PENDING_IDS_FILE}")
      FILTER=$(jq -n -c --argjson inq "${INQ_ARRAY}" '{
        "fields": {"id": true, "name": true, "status": true},
        "where": {"id": {"$inq": $inq}}
      }')
      ENCODED_FILTER=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "${FILTER}")
      QUERY_URL="${API_BASE}/Task?access_token=${TAPDATA_TOKEN}&filter=${ENCODED_FILTER}"

      RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${QUERY_URL}")
      HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
      BODY=$(echo "${RESPONSE}" | sed '$d')

      if [[ "${HTTP_CODE}" -ne 200 ]]; then
        echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to query tasks: HTTP ${HTTP_CODE} - ${BODY}"
        rm -f "${PENDING_IDS_FILE}"
        exit 1
      fi

      # Log current status of all pending tasks
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current task statuses:"
      echo "${BODY}" | jq -r '.data.items[] | "  - \(.name) (id: \(.id)): \(.status)"'

      # Find tasks that can be deleted (status: stop, error, wait_start)
      DELETABLE_STATUSES='["stop", "error", "wait_start"]'
      DELETABLE_IDS=$(echo "${BODY}" | jq -r --argjson s "${DELETABLE_STATUSES}" '[.data.items[] | select(.status as $st | $s | index($st)) | .id] | join("\n")')
      DELETABLE_COUNT=$(echo "${BODY}" | jq --argjson s "${DELETABLE_STATUSES}" '[.data.items[] | select(.status as $st | $s | index($st))] | length')
      NOT_DELETABLE_COUNT=$(echo "${BODY}" | jq --argjson s "${DELETABLE_STATUSES}" '[.data.items[] | select(.status as $st | $s | index($st) | not)] | length')

      if [[ "${DELETABLE_COUNT}" -gt 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Found ${DELETABLE_COUNT} deletable task(s) (stop/error/wait_start), proceeding to delete:"
        echo "${BODY}" | jq -r --argjson s "${DELETABLE_STATUSES}" '.data.items[] | select(.status as $st | $s | index($st)) | "  - \(.name) (id: \(.id), status: \(.status))"'

        # Build batchDelete query params
        TASK_IDS_PARAMS=""
        while IFS= read -r tid; do
          if [[ -z "${tid}" ]]; then continue; fi
          if [[ -n "${TASK_IDS_PARAMS}" ]]; then
            TASK_IDS_PARAMS="${TASK_IDS_PARAMS}&taskIds=${tid}"
          else
            TASK_IDS_PARAMS="taskIds=${tid}"
          fi
        done <<< "${DELETABLE_IDS}"

        DELETE_URL="${API_BASE}/Task/batchDelete?${TASK_IDS_PARAMS}&access_token=${TAPDATA_TOKEN}"
        DEL_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${DELETE_URL}")
        DEL_HTTP_CODE=$(echo "${DEL_RESPONSE}" | tail -n1)
        DEL_BODY=$(echo "${DEL_RESPONSE}" | sed '$d')

        if [[ "${DEL_HTTP_CODE}" -ne 200 ]]; then
          echo "::error::[$(date '+%Y-%m-%d %H:%M:%S')] Failed to batch delete tasks: HTTP ${DEL_HTTP_CODE} - ${DEL_BODY}"
          rm -f "${PENDING_IDS_FILE}"
          exit 1
        fi

        DELETED_COUNT=$((DELETED_COUNT + DELETABLE_COUNT))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Batch delete successful: deleted ${DELETABLE_COUNT} task(s) in this round (total deleted: ${DELETED_COUNT}/${TASK_COUNT}) ✓"

        # Remove deleted IDs from pending list
        DELETED_IDS_JSON=$(echo "${BODY}" | jq -c --argjson s "${DELETABLE_STATUSES}" '[.data.items[] | select(.status as $st | $s | index($st)) | .id]')
        jq --argjson deleted "${DELETED_IDS_JSON}" '[.[] | select(.id as $id | $deleted | index($id) | not)]' \
          "${PENDING_IDS_FILE}" > "${PENDING_IDS_FILE}.tmp"
        mv "${PENDING_IDS_FILE}.tmp" "${PENDING_IDS_FILE}"
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] No deletable tasks in this round, ${NOT_DELETABLE_COUNT} task(s) still waiting to become deletable..."
      fi

      STILL_REMAINING=$(jq 'length' "${PENDING_IDS_FILE}")
      if [[ "${STILL_REMAINING}" -eq 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] All ${TASK_COUNT} task(s) have been deleted successfully ✓"
        break
      fi

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${STILL_REMAINING} task(s) remaining, waiting ${POLL_INTERVAL}s before next round..."
      sleep "${POLL_INTERVAL}"
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done

    rm -f "${PENDING_IDS_FILE}"
  fi
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] No stopped tasks file provided or file not found, skipping task deletion"
fi

echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Clean Resources Complete ==="
