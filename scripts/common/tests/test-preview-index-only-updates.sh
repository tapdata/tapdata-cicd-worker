#!/usr/bin/env bash
# Local unit tests for the "serving-index declarations only" annotation on the Deploy Plan.
# (run: bash scripts/common/tests/test-preview-index-only-updates.sh)
#
# Why this exists: a serving-index declaration is stored INSIDE the Module document
# (that is what makes it travel through CICD for free), so ticking an index checkbox is a
# genuine change to the API document and the APIs leg must still import it -- otherwise the
# declaration never reaches the target environment. But the Deploy Plan rollup only said
# "APIs -- Will deploy", which an approver reads as "the API itself changed": wrong contract,
# wrong fields, worth scrutiny. TM already sends the field-level diff
# (`servingIndexes[6].collected: true -> false`); this annotation lifts that fact into the rollup.
#
# The trap being pinned: annotating whenever ANY change is a serving-index change would let
# "declarations only" cover up a real API change sitting in the same run -- strictly worse than
# no annotation at all. Hence the all/partial split, and hence test 2.
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

note() { sed -n 's/^index_only_note=//p' "${GITHUB_OUTPUT}"; }

echo "== deploy plan: serving-index-only annotation =="

# Test 1: every changed API changed nothing but its serving-index declarations.
# This is the exact payload the 2026-08-04 run produced after unticking one declaration.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[
 {"name":"customer_by_country","changes":[{"field":"servingIndexes[6].collected","from":true,"to":false}]},
 {"name":"customer_by_email","changes":[{"field":"servingIndexes[6].collected","from":true,"to":false}]}
],"delete":[]}}'
bash "${SUT}" apis >/dev/null 2>&1
NOTE="$(note)"
if [[ "${NOTE}" == *"serving-index declarations only"* && "${NOTE}" != *" of "* ]]; then
  pass "全部仅索引声明 → 汇总加注「declarations only」（注记：${NOTE}）"
else
  fail "期望无条件的 declarations only 注记，实得 '${NOTE}'"
fi
teardown

# Test 2: mixed run -- one API really changed, one only had a checkbox ticked. A blanket
# "declarations only" here would hide the real API change from the approver.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[
 {"name":"customer_by_country","changes":[{"field":"servingIndexes[6].collected","from":true,"to":false}]},
 {"name":"customer_by_email","changes":[{"field":"paths[0].path","from":"/a","to":"/b"}]}
],"delete":[]}}'
bash "${SUT}" apis >/dev/null 2>&1
NOTE="$(note)"
if [[ "${NOTE}" == *"1 of 2"* ]]; then
  pass "混合情形 → 注记为部分计数，不掩盖真实 API 变更（注记：${NOTE}）"
else
  fail "混合情形必须给部分计数（期望含 '1 of 2'），实得 '${NOTE}'"
fi
teardown

# Test 3: a real API change alone -- no annotation whatsoever.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[
 {"name":"customer_by_email","changes":[{"field":"paths[0].path","from":"/a","to":"/b"}]}
],"delete":[]}}'
bash "${SUT}" apis >/dev/null 2>&1
NOTE="$(note)"
if [[ -z "${NOTE}" ]]; then
  pass "无索引声明变更 → 不加注"
else
  fail "不该加注，实得 '${NOTE}'"
fi
teardown

# Test 4: an update whose `changes` list is empty. We do NOT know it was index-only, so
# claiming so would be a guess -- and a guess that downplays the change.
setup
export STUB_BODY='{"code":"ok","data":{"add":[],"update":[
 {"name":"customer_by_email","changes":[]}
],"delete":[]}}'
bash "${SUT}" apis >/dev/null 2>&1
NOTE="$(note)"
if [[ -z "${NOTE}" ]]; then
  pass "changes 为空时不臆断为「仅索引声明」"
else
  fail "changes 为空却加注了 '${NOTE}'"
fi
teardown

# Test 5: adds/deletes present alongside index-only updates -- an added or removed API is a
# real change, so the run as a whole is not "declarations only".
setup
export STUB_BODY='{"code":"ok","data":{"add":[{"name":"brand_new_api"}],"update":[
 {"name":"customer_by_country","changes":[{"field":"servingIndexes[6].collected","from":true,"to":false}]}
],"delete":[]}}'
bash "${SUT}" apis >/dev/null 2>&1
NOTE="$(note)"
if [[ "${NOTE}" == *" of "* ]]; then
  pass "有新增 API 时退回部分计数，不说成整体仅索引声明（注记：${NOTE}）"
else
  fail "有新增 API 时不得给无条件注记，实得 '${NOTE}'"
fi
teardown

# Test 6: the note is actually wired into the Deploy Plan row. The computation above can be
# perfect and still show the approver nothing if the workflow drops the interpolation -- the
# failure is silent (a correct-looking rollup that just omits the note). Same technique as
# test-deploy-matrix-indexes.sh: lift the step's `run:` block out of the workflow and run it.
WORKFLOW="${SCRIPT_DIR}/../../../.github/workflows/tapdata-deploy.yml"
plan_row() {
  python3 - "${WORKFLOW}" "$1" <<'PY' > "${WORK}/plan.sh"
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
note = sys.argv[2]
for step in doc['jobs']['preview-all']['steps']:
    if step.get('name') == 'Write Deploy Plan Summary':
        script = step['run']
        break
else:
    raise SystemExit('Write Deploy Plan Summary step not found')
def sub(m):
    expr = m.group(1).strip()
    if expr.endswith('index_only_note'):
        return note
    if expr.endswith('has_changes'):
        return 'true' if 'preview_apis' in expr else 'false'
    return ''
print(re.sub(r'\$\{\{(.*?)\}\}', sub, script))
PY
  bash "${WORK}/plan.sh"
  grep -m1 '^| APIs |' "${GITHUB_STEP_SUMMARY}"
}

setup
ROW="$(plan_row '(serving-index declarations only)')"
if [[ "${ROW}" == *"Will deploy"* && "${ROW}" == *"serving-index declarations only"* ]]; then
  pass "注记接进了 Deploy Plan 的 APIs 行（${ROW}）"
else
  fail "Deploy Plan 的 APIs 行没带上注记：${ROW}"
fi
teardown

echo
if [[ "${FAILS}" -eq 0 ]]; then echo "All tests passed."; else echo "${FAILS} test(s) failed."; exit 1; fi
