#!/usr/bin/env bash
# Preview resource changes (connections/migrate/tasks/sync/tasks/apis/indexes) via TapData API
# Usage: preview-resource.sh <resource_type>
# resource_type: connections | migrate/tasks | sync/tasks | apis | indexes
# Required env vars: DEPLOY_DIR, TAPDATA_TOKEN, TAPDATA_URL
# Optional env vars: ARCHIVE_NAME
set -euo pipefail

RESOURCE_TYPE="${1:-}"

echo "=== Previewing ${RESOURCE_TYPE} via TapData API ==="

# Validate inputs
if [[ -z "${RESOURCE_TYPE}" ]]; then
  echo "::error::Usage: preview-resource.sh <connections|migrate/tasks|sync/tasks|apis|indexes>"
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
    DISPLAY_NAME="Data Replication"
    ;;
  sync/tasks)
    API_PATH="api/groupInfo/preview/sync/tasks"
    DISPLAY_NAME="Data Transformation"
    ;;
  apis)
    API_PATH="api/groupInfo/preview/apis"
    DISPLAY_NAME="APIs"
    ;;
  # TAP-12057: serving indexes travel inside the API package but deploy as their own leg --
  # creating an index is the only step here that is both expensive and risky on a collection
  # that already holds data, so it has to be reviewable on its own. Same archive as apis (the
  # export dir is tarred whole); the plan lists only indexes that would be created, each with
  # its direction spelled out (a declared -1 created as 1 was a real defect).
  indexes)
    API_PATH="api/groupInfo/preview/indexes"
    DISPLAY_NAME="Serving Indexes"
    ;;
  *)
    echo "::error::Unknown resource type: ${RESOURCE_TYPE}. Expected: connections|migrate/tasks|sync/tasks|apis|indexes"
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

# TAP-11891: 与 import-resource.sh 保持一致（preview 的 diff 与导入模式无关，此处仅为统一）
IMPORT_MODE="${IMPORT_MODE:-group_import}"

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
COMMAND_LIST=$(echo "${BODY}" | jq -c '.data.commands // []' 2>/dev/null || echo "[]")

# TAP-12057: orphan indexes -- in the target collection, declared by no API. Flattened across
# targets so the section reads as one list. TM has already dropped `_id_` from this bucket
# (every collection has it; it is not an orphan) while still counting it toward the 64 limit.
ORPHAN_LIST=$(echo "${BODY}" | jq -c '[.data.report.targets[]? | . as $t | (.extra // [])[] | {
  connection: ($t.connectionName // "-"),
  table: ($t.tableName // "-"),
  name: (.name // "-"),
  keys: ((.fields // []) | map(.field + ":" + (if .asc == false then "-1" else "1" end)) | join(",")),
  unique: (.unique // false)
}]' 2>/dev/null || echo "[]")
ORPHAN_COUNT=$(echo "${ORPHAN_LIST}" | jq 'length' 2>/dev/null || echo 0)

ADD_COUNT=$(echo "${ADD_LIST}" | jq 'length')
UPDATE_COUNT=$(echo "${UPDATE_LIST}" | jq 'length')
DELETE_COUNT=$(echo "${DELETE_LIST}" | jq 'length')

echo "Preview results - Add: ${ADD_COUNT}, Update: ${UPDATE_COUNT}, Delete: ${DELETE_COUNT}"

# TAP-12057: how many of the changed APIs changed NOTHING but their serving-index declarations.
#
# A declaration lives inside the Module document -- that is exactly what makes it travel through
# CICD for free -- so ticking an index checkbox is a real change to the API document, and the APIs
# leg must still import it or the declaration never reaches the target environment. The rollup,
# though, said only "APIs -- Will deploy", which an approver reads as "the API itself changed":
# different contract, different fields, worth scrutiny. TM already sends the field-level diff
# (`servingIndexes[6].collected: true -> false`); this lifts that fact up into the rollup.
#
# The all/partial split is load-bearing: annotating whenever ANY change is a serving-index change
# would let "declarations only" paper over a real API change riding along in the same run --
# strictly worse than no annotation. An update with an empty `changes` list is never counted
# either: we do not know what changed, and guessing would downplay it.
INDEX_ONLY_COUNT=$(echo "${UPDATE_LIST}" | jq '[.[]
  | select(type == "object")
  | (.changes // []) as $c
  | select(($c | length) > 0 and all($c[]; (.field // "") | startswith("servingIndexes")))
] | length' 2>/dev/null || echo 0)

INDEX_ONLY_NOTE=""
if [[ "${INDEX_ONLY_COUNT}" -gt 0 ]]; then
  if [[ "${ADD_COUNT}" -eq 0 && "${DELETE_COUNT}" -eq 0 && "${INDEX_ONLY_COUNT}" -eq "${UPDATE_COUNT}" ]]; then
    INDEX_ONLY_NOTE="(serving-index declarations only)"
  else
    INDEX_ONLY_NOTE="(${INDEX_ONLY_COUNT} of ${UPDATE_COUNT} are serving-index declarations only)"
  fi
fi

# 输出 has_changes 标志给 GitHub Actions
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ "${ADD_COUNT}" -eq 0 && "${UPDATE_COUNT}" -eq 0 && "${DELETE_COUNT}" -eq 0 ]]; then
    echo "has_changes=false" >> "${GITHUB_OUTPUT}"
  else
    echo "has_changes=true" >> "${GITHUB_OUTPUT}"
  fi
  echo "index_only_note=${INDEX_ONLY_NOTE}" >> "${GITHUB_OUTPUT}"
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
          (.[] | [to_entries[] | if .value == null or .value == "" then "-" else .value end]
           | map("`\(.)`") | "| \(join(" | ")) |")
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
            val=$(echo "${item_json}" | jq -r --arg k "${key}" 'if .[$k] == null or .[$k] == "" then "-" else .[$k] end | tostring')
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
        (.changes // []) as $rawChanges |

        # 同源行合并：一次字段改动会同时落在顶层 fields[X] 和 paths[P].fields[X] 上，
        # 于是 1 个改动渲染成 2 行。两边 from/to 完全一致时只保留顶层那行。
        #
        # 只在「完全一致」时合并，是这条规则唯一安全的形态：两份清单语义并不相同 ——
        # 顶层 fields 是表的全量字段，paths[].fields 是用户在页面上勾选的对外暴露子集
        # （Drawer.vue: formData.fields = allFields vs paths[].fields = currentCheckedFields()）。
        # 取消勾选某个字段时只有 paths 那行会变，它必须留下，否则部署计划会把
        # 「这个 API 不再对外发某字段」显示成「无变更」。
        ($rawChanges | map(.field + "\u0000" + (.from | tojson) + "\u0000" + (.to | tojson))) as $sigs |
        ($rawChanges | map(
          . as $c |
          ($c.field | sub("^paths\\[[^\\]]*\\]\\."; "")) as $peerField |
          if ($peerField != $c.field)
             and (($sigs | index($peerField + "\u0000" + ($c.from | tojson) + "\u0000" + ($c.to | tojson))) != null)
          then empty else $c end
        )) as $changes |
        (.dagChangeDetail // {}) as $dag |
        ($dag.nodeAdditions // []) as $nodeAdds |
        ($dag.nodeRemovals // []) as $nodeDels |
        ($dag.nodeConfigChanges // []) as $nodeCfgs |
        ($dag.edgeAdditions // []) as $edgeAdds |
        ($dag.edgeRemovals // []) as $edgeDels |
        (($changes | length) + ($nodeAdds | length) + ($nodeDels | length) + ($nodeCfgs | length) + ($edgeAdds | length) + ($edgeDels | length)) as $total |

        "<details>\n<summary><code>\($name)</code> (\($total) change\(if $total == 1 then "" else "s" end))</summary>\n" +

        # Top-level changes table
        #
        # 展示层修正：TM 存的 API 路径名是 "customerQuery"（客户查询），但它表达的是
        # "custom query"（自定义查询）—— 拼写从一开始就错了。那个值是 apiserver 的
        # 运行期契约（按它选代码生成模板、暴露成 OpenAPI operation name），动不得，
        # 所以只在这里把展示改对。
        #
        # 必须锚定整个 "paths[customerQuery]" 段，不能只替换 "customer" 子串：
        # 用户自己的字段常带 CUSTOMER（fields[CUSTOMER_NO]、fields[customerName]），
        # 那些是真实数据，改了就是在计划表里撒谎。
        if ($changes | length) > 0 then
          "\n**Config Changes**\n\n| Field | From | To |\n| --- | --- | --- |\n" +
          ($changes | map("| `\(.field | gsub("paths\\[customerQuery\\]"; "paths[customQuery]"))` | `\(if .from == null or .from == "" then "-" else .from end)` | `\(if .to == null or .to == "" then "-" else .to end)` |") | join("\n")) + "\n"
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
        (.[] | [to_entries[] | if .value == null or .value == "" then "-" else .value end]
           | map("`\(.)`") | "| \(join(" | ")) |")
      else empty end
    '
    echo ""
  fi

  # TAP-12057: manual creation commands. TM emits them only for MongoDB connections --
  # every other data source has its own index DDL, and a generated statement that might
  # not run (or worse, run wrongly) is worse than none. Rendered as a copyable code block
  # BELOW the table, never as a column: a createIndex statement is far too long for a cell.
  if [[ -n "${COMMAND_LIST}" && "${COMMAND_LIST}" != "[]" ]]; then
    COMMAND_COUNT=$(echo "${COMMAND_LIST}" | jq 'length')
    if [[ "${COMMAND_COUNT}" -gt 0 ]]; then
      echo "### 🖥️ Manual commands (${COMMAND_COUNT})"
      echo ""
      echo '```javascript'
      echo "${COMMAND_LIST}" | jq -r '.[]'
      echo '```'
      echo ""
    fi
  fi

  # TAP-12057: orphan indexes. These can never appear in the plan table -- they are not a change,
  # so add/update/delete stay 0, the leg is skipped, and the summary otherwise says
  # "No changes detected". But they are real cost: write amplification on every write, one slot
  # out of MongoDB's 64-per-collection budget, and no one left who knows if dropping them is safe.
  # Every rollback manufactures them (APIs revert, indexes are only-add and do not). The platform
  # will not drop them -- that is ADR-0005/0008, not an oversight -- so the least it owes the
  # operator is to say they are there. Direction is spelled out: an orphan LAST_CHANGE:-1 and a
  # declared LAST_CHANGE:1 are different indexes.
  if [[ "${ORPHAN_COUNT}" -gt 0 ]]; then
    echo "### 🗂️ Orphan indexes (${ORPHAN_COUNT})"
    echo ""
    echo "> In the target collection, declared by no API. The platform never drops them — review and clean up by hand."
    echo ""
    echo "| connection | table | name | keys | unique |"
    echo "| --- | --- | --- | --- | --- |"
    echo "${ORPHAN_LIST}" | jq -r '.[] | "| `\(.connection)` | `\(.table)` | `\(.name)` | `\(.keys)` | `\(.unique)` |"'
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
