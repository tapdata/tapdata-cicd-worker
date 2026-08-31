#!/usr/bin/env bash
# Local unit tests for the preview markdown table renderer.
# (run: bash scripts/common/tests/test-preview-markdown-render.sh)
#
# The renderer is generic -- every resource type's plan table goes through it -- so a
# rendering bug here silently corrupts what the approver reads at the deploy gate.
#
# The bug these tests pin: jq's `//` is the ALTERNATIVE operator, and when its left
# side is a *stream* it emits only the TRUTHY outputs. `[to_entries[].value // "-"]`
# therefore DROPS every false / null / "" / 0 value from the row instead of rendering
# it, so the row ends up short and every later column shifts one cell to the left --
# values land under the wrong header. Found 2026-08-04 on the serving-index leg, whose
# rows are the first to carry a boolean `unique: false`, but the defect is generic.
#
# curl is stubbed via PATH so no TapData instance is needed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/../preview-resource.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

setup() {
  WORK="$(mktemp -d)"
  export DEPLOY_DIR="${WORK}/deploy"
  mkdir -p "${DEPLOY_DIR}" "${WORK}/bin"
  export ARCHIVE_NAME="apis-export.tar"
  printf 'not-a-real-tar' > "${DEPLOY_DIR}/${ARCHIVE_NAME}"
  export TAPDATA_TOKEN="token-123"
  export TAPDATA_URL="http://tm.example.com"
  export TARGET_ENV="test"
  export GITHUB_OUTPUT="${WORK}/gh_output"; : > "${GITHUB_OUTPUT}"
  export GITHUB_STEP_SUMMARY="${WORK}/gh_summary"; : > "${GITHUB_STEP_SUMMARY}"

  cat > "${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n200' "${STUB_BODY}"
STUB
  chmod +x "${WORK}/bin/curl"
  export PATH="${WORK}/bin:${PATH}"
}
teardown() { rm -rf "${WORK}"; }

# Number of cells in a markdown table row: "| a | b |" -> 2
cells() { awk -F'|' '{print NF-2}' <<<"$1"; }

# The rows the serving-index leg actually produced on 2026-08-04 (4 of 5 have unique=false).
export STUB_BODY='{"code":"ok","data":{"add":[
 {"connection":"mdm","table":"MDM_CUSTOMER","name":"CITY_1","keys":"CITY:1","unique":false,"declaredBy":"customer_by_country, customer_by_email"},
 {"connection":"mdm","table":"MDM_CUSTOMER","name":"EMAIL_1_CUSTOMER_ID_1","keys":"EMAIL:1,CUSTOMER_ID:1","unique":true,"declaredBy":"customer_by_email"}
],"update":[],"delete":[]}}'

echo "== preview markdown table =="

# Test 1: every data row has exactly as many cells as the header.
setup
bash "${SUT}" indexes >/dev/null 2>&1
HEADER=$(grep -m1 '^| connection |' "${GITHUB_STEP_SUMMARY}")
HEADER_CELLS=$(cells "${HEADER}")
MISALIGNED=0
while IFS= read -r row; do
  [[ "${row}" == "${HEADER}" ]] && continue
  [[ "${row}" =~ ^\|\ --- ]] && continue
  [[ "$(cells "${row}")" -ne "${HEADER_CELLS}" ]] && MISALIGNED=$((MISALIGNED+1))
done < <(grep '^| ' "${GITHUB_STEP_SUMMARY}")
if [[ "${HEADER_CELLS}" -eq 6 && "${MISALIGNED}" -eq 0 ]]; then
  pass "每一行的单元格数都与表头一致（${HEADER_CELLS} 列）"
else
  fail "有 ${MISALIGNED} 行与 ${HEADER_CELLS} 列的表头对不齐——列会左移、值落到别的表头下"
  grep '^| ' "${GITHUB_STEP_SUMMARY}" | sed 's/^/       /'
fi
teardown

# Test 2: a false boolean renders as `false`, not swallowed and not turned into "-".
setup
bash "${SUT}" indexes >/dev/null 2>&1
ROW=$(grep -m1 'CITY_1' "${GITHUB_STEP_SUMMARY}")
UNIQUE_CELL=$(awk -F'|' '{gsub(/[ `]/,"",$6); print $6}' <<<"${ROW}")
if [[ "${UNIQUE_CELL}" == "false" ]]; then
  pass "unique=false 渲染成 \`false\`"
else
  fail "unique 列渲染成 '${UNIQUE_CELL}'，期望 'false'（整行：${ROW}）"
fi
teardown

# Test 3: the API names stay in their own column (this is what a reviewer reads to
# answer "which APIs need this index?").
setup
bash "${SUT}" indexes >/dev/null 2>&1
ROW=$(grep -m1 'CITY_1' "${GITHUB_STEP_SUMMARY}")
DECLARED_CELL=$(awk -F'|' '{gsub(/^[ `]+|[ `]+$/,"",$7); print $7}' <<<"${ROW}")
if [[ "${DECLARED_CELL}" == "customer_by_country, customer_by_email" ]]; then
  pass "declaredBy 落在自己的列里"
else
  fail "declaredBy 列是 '${DECLARED_CELL}'（整行：${ROW}）"
fi
teardown

# Test 4: manual commands (TM only emits them for MongoDB) render as a copyable code block
# below the table. They are deliberately NOT a table column -- a createIndex statement is far
# too long for a cell and would wreck the plan table.
setup
export STUB_BODY='{"code":"ok","data":{"add":[
 {"connection":"mdm","table":"MDM_CUSTOMER","name":"LAST_CHANGE_-1","keys":"LAST_CHANGE:-1","unique":false,"declaredBy":"customer_by_country"}
],"update":[],"delete":[],"commands":[
 "db.MDM_CUSTOMER.createIndex({ \"LAST_CHANGE\": -1 }, { name: \"LAST_CHANGE_-1\", background: true })"
]}}'
bash "${SUT}" indexes >/dev/null 2>&1
if grep -q 'createIndex' "${GITHUB_STEP_SUMMARY}" && grep -q '```' "${GITHUB_STEP_SUMMARY}"; then
  pass "手工执行语句渲染成代码块"
else
  fail "摘要里没有手工执行语句的代码块"
fi
teardown

# Test 5: no commands in the response (non-MongoDB, or none applicable) -> no empty block.
setup
export STUB_BODY='{"code":"ok","data":{"add":[
 {"connection":"pg","table":"CUSTOMER","name":"CITY_1","keys":"CITY:1","unique":false,"declaredBy":"api"}
],"update":[],"delete":[]}}'
bash "${SUT}" indexes >/dev/null 2>&1
if grep -q 'createIndex' "${GITHUB_STEP_SUMMARY}"; then
  fail "响应里没有 commands，却渲染出了语句块"
else
  pass "无手工语句时不渲染空块（非 MongoDB 数据源）"
fi
teardown

# Test 6: orphan indexes -- present in the target collection, declared by no API. The platform
# never drops them (only-add, ADR-0005/0008), so they are pure cost: write amplification on every
# write, one slot out of MongoDB's 64-per-collection budget, and nobody left who knows whether
# they are safe to drop. Every rollback manufactures them (APIs go back, indexes do not), and the
# plan table cannot show them -- they are not a change, so add/update/delete stay 0 and the leg is
# skipped entirely. Without this section an operator reads "Serving Indexes — No changes" and
# concludes the target is clean.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[],"delete":[],"report":{"targets":[
 {"connectionName":"mdm","tableName":"MDM_CUSTOMER","create":[],"skip":[],
  "extra":[{"name":"POLICY.POLICY_STATUS_1","fields":[{"field":"POLICY.POLICY_STATUS","asc":true}],"unique":false}]}
]}}}'
bash "${SUT}" indexes >/dev/null 2>&1
if grep -qi 'orphan' "${GITHUB_STEP_SUMMARY}" && grep -q 'POLICY.POLICY_STATUS_1' "${GITHUB_STEP_SUMMARY}"; then
  pass "孤儿索引单独成段列出（计划表为空时也要出现）"
else
  fail "摘要里没有孤儿索引段落"
  cat "${GITHUB_STEP_SUMMARY}" | sed 's/^/       /'
fi
teardown

# Test 7: direction must be spelled out here too -- an orphan `LAST_CHANGE:-1` and a declared
# `LAST_CHANGE:1` are different indexes, and telling them apart is the whole point of the keys column.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[],"delete":[],"report":{"targets":[
 {"connectionName":"mdm","tableName":"MDM_CUSTOMER","create":[],"skip":[],
  "extra":[{"name":"stale_desc","fields":[{"field":"LAST_CHANGE","asc":false}],"unique":false}]}
]}}}'
bash "${SUT}" indexes >/dev/null 2>&1
ROW=$(grep -m1 'stale_desc' "${GITHUB_STEP_SUMMARY}")
if [[ "${ROW}" == *"LAST_CHANGE:-1"* ]]; then
  pass "孤儿索引也带方向（${ROW}）"
else
  fail "孤儿索引没写明方向，无法与同字段升序索引区分：${ROW}"
fi
teardown

# Test 8: no orphans -> no empty section. The clean case is the common case; a permanently
# present "Orphan indexes (0)" heading trains people to ignore the section.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[],"delete":[],"report":{"targets":[
 {"connectionName":"mdm","tableName":"MDM_CUSTOMER","create":[],"skip":[],"extra":[]}
]}}}'
bash "${SUT}" indexes >/dev/null 2>&1
if grep -qi 'orphan' "${GITHUB_STEP_SUMMARY}"; then
  fail "没有孤儿索引却渲染出了空段落"
else
  pass "无孤儿索引时不渲染空段落"
fi
teardown

# Test 9/10: the "customerQuery" spelling. TM stores the API path name as "customerQuery"
# (客户查询) where it means "custom query" (自定义查询). That value is apiserver's runtime
# contract -- controller.ts.ejs picks partials/customerQuery.ejs by it, and it surfaces as the
# OpenAPI x-operation-name -- so it cannot be renamed. Only this plan table is corrected.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"delete":[],"update":[
 {"name":"API_PATIENT","changes":[
  {"field":"paths[customerQuery].fields[ccCodes]","from":"cc","to":null},
  {"field":"fields[CUSTOMER_NO]","from":"a","to":"b"},
  {"field":"paths[customerQuery].fields[customerName]","from":"x","to":"y"}
 ]}]}}'
bash "${SUT}" apis >/dev/null 2>&1

# 9: the path segment is displayed corrected.
if grep -q 'paths\[customQuery\]' "${GITHUB_STEP_SUMMARY}" && ! grep -q 'paths\[customerQuery\]' "${GITHUB_STEP_SUMMARY}"; then
  pass "paths[customerQuery] 展示成 paths[customQuery]"
else
  fail "路径段没改对，摘要里是：$(grep -o 'paths\[[a-zA-Z]*\]' "${GITHUB_STEP_SUMMARY}" | sort -u | tr '\n' ' ')"
fi

# 10: THE discriminating one -- a blunt gsub("customer";"custom") passes test 9 and fails here.
# CUSTOMER_NO / customerName are the user's own field names; rewriting them makes the plan
# table describe a change other than the one being deployed.
if grep -q 'fields\[CUSTOMER_NO\]' "${GITHUB_STEP_SUMMARY}" && grep -q 'fields\[customerName\]' "${GITHUB_STEP_SUMMARY}"; then
  pass "用户自己的 CUSTOMER_NO / customerName 字段原样保留"
else
  fail "把用户的真实字段名一起改了——摘要里的字段：$(grep -o 'fields\[[a-zA-Z_]*\]' "${GITHUB_STEP_SUMMARY}" | sort -u | tr '\n' ' ')"
fi
teardown

# ---------------------------------------------------------------------------
# Same-source row merge. Renaming one field writes it into BOTH Module.fields
# (the table's full field list) and Module.paths[].fields (the subset the user
# ticked for the API), so one edit renders as two identical rows. Merging them
# is only safe when from/to match exactly -- the two lists are NOT the same set.
# ---------------------------------------------------------------------------

# Test 11: Martin's actual case -- ccCodes renamed to ccCodesV3. 4 rows collapse to 2,
# and the <summary> count must follow, or the header contradicts the table under it.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"delete":[],"update":[
 {"name":"API_PATIENT","changes":[
  {"field":"fields[ccCodes]","from":"{\"field_name\":\"ccCodes\"}","to":null},
  {"field":"fields[ccCodesV3]","from":null,"to":"{\"field_name\":\"ccCodesV3\"}"},
  {"field":"paths[customerQuery].fields[ccCodes]","from":"{\"field_name\":\"ccCodes\"}","to":null},
  {"field":"paths[customerQuery].fields[ccCodesV3]","from":null,"to":"{\"field_name\":\"ccCodesV3\"}"},
  {"field":"tableName","from":"MDM_PATIENT_V2","to":"MDM_PATIENT_V3"}
 ]}]}}'
bash "${SUT}" apis >/dev/null 2>&1
PATH_ROWS=$(grep -c 'paths\[custom' "${GITHUB_STEP_SUMMARY}" || true)
if [[ "${PATH_ROWS}" -eq 0 ]] && grep -q 'fields\[ccCodesV3\]' "${GITHUB_STEP_SUMMARY}"; then
  pass "同源行合并：重命名的 paths[] 重复行被去掉，顶层行保留"
else
  fail "还剩 ${PATH_ROWS} 行 paths[...] 重复行"
fi
if grep -q '(3 changes)' "${GITHUB_STEP_SUMMARY}"; then
  pass "summary 计数跟着合并后的行数走（3 changes）"
else
  fail "summary 计数没跟上：$(grep -o '([0-9]* changes\?)' "${GITHUB_STEP_SUMMARY}" | head -1)"
fi
teardown

# Test 12: THE discriminating one. The user UNTICKED a field: it leaves
# paths[].fields but stays in the table's full Module.fields, so ONLY the paths row
# exists. Dropping paths rows wholesale (what was originally proposed) renders this
# as "no changes" -- the approver green-lights a deploy that silently stops exposing
# a field. The row must survive precisely because it has no identical top-level peer.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"delete":[],"update":[
 {"name":"API_PATIENT","changes":[
  {"field":"paths[customerQuery].fields[SSN]","from":"{\"field_name\":\"SSN\"}","to":null}
 ]}]}}'
bash "${SUT}" apis >/dev/null 2>&1
if grep -q 'fields\[SSN\]' "${GITHUB_STEP_SUMMARY}"; then
  pass "取消勾选：没有同源顶层行时，paths 行必须保留（否则计划显示成无变更）"
else
  fail "取消勾选的字段在计划表里消失了——审批的人会看到「无变更」：$(grep -o 'fields\[[A-Za-z_]*\]' "${GITHUB_STEP_SUMMARY}" | tr '\n' ' ')"
fi
teardown

# Test 13: same field name at both levels but DIFFERENT values -- not the same edit,
# so nothing may be merged away. Guards a signature check that compares only .field.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"delete":[],"update":[
 {"name":"API_PATIENT","changes":[
  {"field":"fields[age]","from":"int","to":"long"},
  {"field":"paths[customerQuery].fields[age]","from":"int","to":"string"}
 ]}]}}'
bash "${SUT}" apis >/dev/null 2>&1
if grep -q 'paths\[customQuery\].fields\[age\]' "${GITHUB_STEP_SUMMARY}" && grep -q '| `fields\[age\]` |' "${GITHUB_STEP_SUMMARY}"; then
  pass "from/to 不一致时两行都保留（不是同一次改动）"
else
  fail "值不同却被合并了——丢掉了一处真实差异"
fi
teardown

echo
if [[ "${FAILS}" -eq 0 ]]; then echo "All tests passed."; else echo "${FAILS} test(s) failed."; exit 1; fi
