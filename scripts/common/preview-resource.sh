#!/usr/bin/env bash
# Preview resource changes (connections/migrate/tasks/sync/tasks/apis) via TapData API
# Usage: preview-resource.sh <resource_type>
# resource_type: connections | migrate/tasks | sync/tasks | apis
# Required env vars: DEPLOY_DIR, TAPDATA_TOKEN, TAPDATA_URL
# Optional env vars: ARCHIVE_NAME
set -euo pipefail

RESOURCE_TYPE="${1:-}"

echo "=== Previewing ${RESOURCE_TYPE} via TapData API ==="

# Validate inputs
if [[ -z "${RESOURCE_TYPE}" ]]; then
  echo "::error::Usage: preview-resource.sh <connections|migrate/tasks|sync/tasks|apis>"
  exit 1
fi

if [[ -z "${DEPLOY_DIR:-}" ]]; then
  echo "::error::DEPLOY_DIR is not set or empty"
  exit 1
fi

if [[ -z "${TAPDATA_TOKEN:-}" ]]; then
  echo "::error::TAPDATA_TOKEN is not set or empty"
  exit 1
fi

if [[ -z "${TAPDATA_URL:-}" ]]; then
  echo "::error::TAPDATA_URL is not set or empty"
  exit 1
fi

BASE_URL="${TAPDATA_URL}"

# Determine API path based on resource type
case "${RESOURCE_TYPE}" in
  connections)
    API_PATH="api/groupInfo/preview/connections"
    DISPLAY_NAME="Connections"
    ;;
  migrate/tasks)
    API_PATH="api/groupInfo/preview/migrate/tasks"
    DISPLAY_NAME="Migrate Tasks"
    ;;
  sync/tasks)
    API_PATH="api/groupInfo/preview/sync/tasks"
    DISPLAY_NAME="Sync Tasks"
    ;;
  apis)
    API_PATH="api/groupInfo/preview/apis"
    DISPLAY_NAME="APIs"
    ;;
  *)
    echo "::error::Unknown resource type: ${RESOURCE_TYPE}. Expected: connections|migrate/tasks|sync/tasks|apis"
    exit 1
    ;;
esac

API_URL="${BASE_URL%/}/${API_PATH}"
ACCESS_TOKEN_ENCODED=$(jq -nr --arg v "${TAPDATA_TOKEN}" '$v|@uri')

if [[ "${API_URL}" == *\?* ]]; then
  PREVIEW_URL="${API_URL}&access_token=${ACCESS_TOKEN_ENCODED}"
else
  PREVIEW_URL="${API_URL}?access_token=${ACCESS_TOKEN_ENCODED}"
fi

# Locate tar archive
ARCHIVE_NAME="${ARCHIVE_NAME:-export.tar}"
ARCHIVE="${DEPLOY_DIR}/${ARCHIVE_NAME}"

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "::error::Archive not found: ${ARCHIVE}"
  exit 1
fi

echo "Target environment: ${TARGET_ENV:-unknown}"
echo "API URL: ${API_URL}"

IMPORT_MODE="${IMPORT_MODE:-replace}"

echo "Archive: ${ARCHIVE}"
echo "Import mode: ${IMPORT_MODE}"

# Build curl arguments for multipart/form-data upload
CURL_ARGS=(-s -w "\n%{http_code}" -X POST "${PREVIEW_URL}" \
  -F "file=@${ARCHIVE}" \
  -F "importMode=${IMPORT_MODE}")

# Optionally attach vault file
VAULT_FILE="${DEPLOY_DIR}/vault.json"
if [[ -f "${VAULT_FILE}" ]]; then
  echo "Vault file found: ${VAULT_FILE}"
  CURL_ARGS+=(-F "vault=@${VAULT_FILE}")
fi

# Upload via POST multipart/form-data
RESPONSE=$(curl "${CURL_ARGS[@]}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

echo "HTTP Status: ${HTTP_CODE}"
echo "Response: ${BODY}"

if [[ "${HTTP_CODE}" -ne 200 ]]; then
  echo "::error::Preview API returned HTTP ${HTTP_CODE}: ${BODY}"
  exit 1
fi

# Check response for errors
CODE=$(echo "${BODY}" | jq -r '.code // empty')
if [[ -n "${CODE}" && "${CODE}" != "ok" ]]; then
  MESSAGE=$(echo "${BODY}" | jq -r '.message // empty')
  echo "::error::Preview failed with code '${CODE}': ${MESSAGE}"
  exit 1
fi

# Extract add/update/delete arrays from response
ADD_LIST=$(echo "${BODY}" | jq -r '.data.add // []')
UPDATE_LIST=$(echo "${BODY}" | jq -r '.data.update // []')
DELETE_LIST=$(echo "${BODY}" | jq -r '.data.delete // []')

ADD_COUNT=$(echo "${ADD_LIST}" | jq 'length')
UPDATE_COUNT=$(echo "${UPDATE_LIST}" | jq 'length')
DELETE_COUNT=$(echo "${DELETE_LIST}" | jq 'length')

echo "Preview results - Add: ${ADD_COUNT}, Update: ${UPDATE_COUNT}, Delete: ${DELETE_COUNT}"

# 输出 has_changes 标志给 GitHub Actions
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ "${ADD_COUNT}" -eq 0 && "${UPDATE_COUNT}" -eq 0 && "${DELETE_COUNT}" -eq 0 ]]; then
    echo "has_changes=false" >> "${GITHUB_OUTPUT}"
  else
    echo "has_changes=true" >> "${GITHUB_OUTPUT}"
  fi
fi

# Build markdown content
MARKDOWN_TMPFILE=$(mktemp)
{
  echo "## Preview: ${DISPLAY_NAME}"
  echo ""

  if [[ "${ADD_COUNT}" -eq 0 && "${UPDATE_COUNT}" -eq 0 && "${DELETE_COUNT}" -eq 0 ]]; then
    echo "> No changes detected."
    echo ""
  fi

  if [[ "${ADD_COUNT}" -gt 0 ]]; then
    echo "### ➕ Add (${ADD_COUNT})"
    echo ""

    HAS_COMPLEX=$(echo "${ADD_LIST}" | jq '[.[] | select(type == "object") | to_entries[] | select(.value | type == "object" or type == "array")] | length > 0')

    if [[ "${HAS_COMPLEX}" == "false" ]]; then
      # Simple rendering: plain list or table
      echo "${ADD_LIST}" | jq -r '
        if all(type == "string") then
          .[] | "- `\(.)`"
        elif length > 0 then
          (.[0] | keys_unsorted) as $keys |
          "| \($keys | join(" | ")) |",
          "| \($keys | map("---") | join(" | ")) |",
          (.[] | [to_entries[].value // "-"] | map("`\(.)`") | "| \(join(" | ")) |")
        else empty end
      '
    else
      # Complex rendering: <details>/<summary> per item with formatted JSON for complex fields
      item_count=$(echo "${ADD_LIST}" | jq 'length')
      for (( i=0; i<item_count; i++ )); do
        item_json=$(echo "${ADD_LIST}" | jq ".[$i]")
        if echo "${item_json}" | jq -e 'type == "string"' >/dev/null 2>&1; then
          echo "- \`$(echo "${item_json}" | jq -r '.')\`"
          continue
        fi
        display_name=$(echo "${item_json}" | jq -r '.name // .id // .tableName // "item"')
        echo "<details>"
        echo "<summary><code>${display_name}</code></summary>"
        echo ""

        # Separate scalar and complex fields
        scalar_keys=$(echo "${item_json}" | jq -r '[to_entries[] | select(.value | type != "object" and type != "array") | .key] | .[]')
        complex_keys=$(echo "${item_json}" | jq -r '[to_entries[] | select(.value | type == "object" or type == "array") | .key] | .[]')

        # Render scalar fields as table
        if [[ -n "${scalar_keys}" ]]; then
          echo "| Field | Value |"
          echo "| --- | --- |"
          while IFS= read -r key; do
            val=$(echo "${item_json}" | jq -r --arg k "${key}" '.[$k] // "-" | tostring')
            echo "| \`${key}\` | \`${val}\` |"
          done <<< "${scalar_keys}"
          echo ""
        fi

        # Render complex fields as formatted JSON code blocks
        if [[ -n "${complex_keys}" ]]; then
          while IFS= read -r key; do
            echo "**${key}**"
            echo ""
            echo '```json'
            echo "${item_json}" | jq --arg k "${key}" '.[$k]'
            echo '```'
            echo ""
          done <<< "${complex_keys}"
        fi

        echo "</details>"
        echo ""
      done
    fi
    echo ""
  fi

  if [[ "${UPDATE_COUNT}" -gt 0 ]]; then
    echo "### ✏️ Update (${UPDATE_COUNT})"
    echo ""
    echo "${UPDATE_LIST}" | jq -r '
      .[] |
      if type == "string" then
        "- `\(.)`"
      else
        # Resource name and top-level changes
        (.name // .id // "unknown") as $name |
        (.changes // []) as $changes |
        (.dagChangeDetail // {}) as $dag |
        ($dag.nodeAdditions // []) as $nodeAdds |
        ($dag.nodeRemovals // []) as $nodeDels |
        ($dag.nodeConfigChanges // []) as $nodeCfgs |
        ($dag.edgeAdditions // []) as $edgeAdds |
        ($dag.edgeRemovals // []) as $edgeDels |
        (($changes | length) + ($nodeAdds | length) + ($nodeDels | length) + ($nodeCfgs | length) + ($edgeAdds | length) + ($edgeDels | length)) as $total |

        "<details>\n<summary><code>\($name)</code> (\($total) change\(if $total == 1 then "" else "s" end))</summary>\n" +

        # Top-level changes table
        if ($changes | length) > 0 then
          "\n**Config Changes**\n\n| Field | From | To |\n| --- | --- | --- |\n" +
          ($changes | map("| `\(.field)` | `\(.from // "-")` | `\(.to // "-")` |") | join("\n")) + "\n"
        else "" end +

        # Node additions
        if ($nodeAdds | length) > 0 then
          "\n**Node Additions:** " + ([$nodeAdds[].name // $nodeAdds[].id // "unknown"] | map("`\(.)`") | join(", ")) + "\n"
        else "" end +

        # Node removals
        if ($nodeDels | length) > 0 then
          "\n**Node Removals:** " + ([$nodeDels[].name // $nodeDels[].id // "unknown"] | map("`\(.)`") | join(", ")) + "\n"
        else "" end +

        # Node config changes
        if ($nodeCfgs | length) > 0 then
          "\n**Node Config Changes** (\($nodeCfgs | length))\n\n| Field | From | To |\n| --- | --- | --- |\n" +
          ($nodeCfgs | map(
            (.field | split(".") | last) as $shortField |
            (if .from then (.from | if type == "object" then "\(.op // ""): \(.field // "")" else tostring end) else "-" end) as $fromVal |
            (if .to then (.to | if type == "object" then "\(.op // ""): \(.field // "")" else tostring end) else "-" end) as $toVal |
            "| `\($shortField)` | \($fromVal) | \($toVal) |"
          ) | join("\n")) + "\n"
        else "" end +

        # Edge changes
        if ($edgeAdds | length) > 0 then "\n**Edge Additions:** \($edgeAdds | length)\n" else "" end +
        if ($edgeDels | length) > 0 then "\n**Edge Removals:** \($edgeDels | length)\n" else "" end +

        "\n</details>"
      end
    '
    echo ""
  fi

  if [[ "${DELETE_COUNT}" -gt 0 ]]; then
    echo "### 🗑️ Delete (${DELETE_COUNT})"
    echo ""
    echo "${DELETE_LIST}" | jq -r '
      if all(type == "string") then
        .[] | "- `\(.)`"
      elif length > 0 then
        (.[0] | keys_unsorted) as $keys |
        "| \($keys | join(" | ")) |",
        "| \($keys | map("---") | join(" | ")) |",
        (.[] | [to_entries[].value // "-"] | map("`\(.)`") | "| \(join(" | ")) |")
      else empty end
    '
    echo ""
  fi
} > "${MARKDOWN_TMPFILE}"

# Write to GitHub Step Summary (skip when called from deploy job)
if [[ "${SKIP_SUMMARY:-}" != "true" ]]; then
  cat "${MARKDOWN_TMPFILE}" >> "${GITHUB_STEP_SUMMARY}"
fi

# Optionally save markdown to a separate file for artifact upload
if [[ -n "${PREVIEW_MARKDOWN_OUTPUT:-}" ]]; then
  cp "${MARKDOWN_TMPFILE}" "${PREVIEW_MARKDOWN_OUTPUT}"
  echo "Preview markdown saved to: ${PREVIEW_MARKDOWN_OUTPUT}"
fi

rm -f "${MARKDOWN_TMPFILE}"

# Save response for downstream steps
SAFE_NAME="${RESOURCE_TYPE//\//_}"
echo "${BODY}" > "${DEPLOY_DIR}/${SAFE_NAME}-preview-response.json"

echo "=== Preview ${RESOURCE_TYPE} Complete ==="
