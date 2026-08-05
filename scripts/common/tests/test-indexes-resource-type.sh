#!/usr/bin/env bash
# Local unit tests for the `indexes` resource type (TAP-12057 · P4-2)
# (run: bash scripts/common/tests/test-indexes-resource-type.sh)
#
# The serving-index leg is a separate deploy leg on purpose: creating indexes is the
# only step in the pipeline that is both expensive and risky on a collection that
# already holds data, so it must be visible and reviewable on its own in the plan.
#
# These tests pin the two things the leg depends on:
#   1. the URL each resource type maps to (TM has no other way to tell the legs apart);
#   2. `code != "ok"` fails the step -- an index that was NOT created must never pass
#      as a green deploy. TM returns ServingIndex.Landing.HasProblems for that case.
#
# curl is stubbed via PATH so no TapData instance is needed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREVIEW_SUT="${SCRIPT_DIR}/../preview-resource.sh"
IMPORT_SUT="${SCRIPT_DIR}/../import-resource.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# Stub curl: records the URL it was called with, replies with ${STUB_BODY} + HTTP 200.
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
  export STUB_URL_LOG="${WORK}/curl-url"
  export STUB_BODY='{"code":"ok","data":{"add":[],"update":[],"delete":[]}}'

  cat > "${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "${arg}" in http*) echo "${arg}" >> "${STUB_URL_LOG}" ;; esac
done
printf '%s\n200' "${STUB_BODY}"
STUB
  chmod +x "${WORK}/bin/curl"
  export PATH="${WORK}/bin:${PATH}"
}
teardown() { rm -rf "${WORK}"; }
called_url() { tail -1 "${STUB_URL_LOG}" 2>/dev/null; }
out() { grep "^$1=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-; }

echo "== preview-resource.sh =="

# Test 1: indexes maps to the preview endpoint TM exposes for the serving-index leg.
setup
bash "${PREVIEW_SUT}" indexes >/dev/null 2>&1
if [[ "$(called_url)" == "http://tm.example.com/api/groupInfo/preview/indexes?access_token=token-123" ]]; then
  pass "preview indexes -> /api/groupInfo/preview/indexes"
else fail "preview indexes -> /api/groupInfo/preview/indexes (got: $(called_url))"; fi
teardown

# Test 2: an empty plan means "nothing to create" -> the leg is left out of the matrix.
setup
bash "${PREVIEW_SUT}" indexes >/dev/null 2>&1
if [[ "$(out has_changes)" == "false" ]]; then
  pass "preview indexes: empty plan => has_changes=false"
else fail "preview indexes: empty plan => has_changes=false (got: $(out has_changes))"; fi
teardown

# Test 3: indexes to create => the leg shows up in the deploy plan, and the rendered
# table keeps the direction visible (declaring -1 and creating 1 is the P0 defect).
setup
export STUB_BODY='{"code":"ok","data":{"add":[{"connection":"fdm","table":"MDM_CUSTOMER","name":"CUSTOMER_ID_-1","keys":"CUSTOMER_ID:-1","unique":false,"declaredBy":"customer"}],"update":[],"delete":[]}}'
bash "${PREVIEW_SUT}" indexes >/dev/null 2>&1
if [[ "$(out has_changes)" == "true" ]] && grep -q "CUSTOMER_ID:-1" "${GITHUB_STEP_SUMMARY}"; then
  pass "preview indexes: planned index => has_changes=true, direction rendered"
else fail "preview indexes: planned index => has_changes=true, direction rendered"; fi
teardown

# Test 4: the leg is named in the summary heading, so it can be reviewed on its own.
setup
bash "${PREVIEW_SUT}" indexes >/dev/null 2>&1
if grep -qi "^## Preview: .*Index" "${GITHUB_STEP_SUMMARY}"; then
  pass "preview indexes: summary heading names the leg"
else fail "preview indexes: summary heading names the leg"; fi
teardown

# Test 5: unknown types still rejected -- the whitelist must stay a whitelist.
setup
if ! bash "${PREVIEW_SUT}" bogus >/dev/null 2>&1; then
  pass "preview: unknown resource type still rejected"
else fail "preview: unknown resource type still rejected"; fi
teardown

echo "== import-resource.sh =="

# Test 6: indexes maps to the import endpoint.
setup
bash "${IMPORT_SUT}" indexes >/dev/null 2>&1
if [[ "$(called_url)" == "http://tm.example.com/api/groupInfo/import/indexes?access_token=token-123" ]]; then
  pass "import indexes -> /api/groupInfo/import/indexes"
else fail "import indexes -> /api/groupInfo/import/indexes (got: $(called_url))"; fi
teardown

# Test 7: what actually got created flows on to downstream jobs.
setup
export STUB_BODY='{"code":"ok","data":{"diff":{"add":[{"connection":"fdm","table":"MDM_CUSTOMER","name":"CUSTOMER_ID_1","keys":"CUSTOMER_ID:1","unique":false,"declaredBy":"customer"}],"update":[],"delete":[]}}}'
bash "${IMPORT_SUT}" indexes >/dev/null 2>&1
if [[ "$(out changed_indexes)" == *'"name":"CUSTOMER_ID_1"'* ]]; then
  pass "import indexes: created indexes reported as changed_indexes"
else fail "import indexes: created indexes reported as changed_indexes (got: $(out changed_indexes))"; fi
teardown

# Test 8: THE one that matters -- TM says an index was reported created but is absent
# on re-read; the step must go red instead of passing the connector's lie along.
setup
export STUB_BODY='{"code":"ServingIndex.Landing.HasProblems","message":"serving index landing has problems: fdm(x).MDM_CUSTOMER: CUSTOMER_ID_-1: reported created but absent on re-read","data":{"diff":{"add":[],"update":[],"delete":[]}}}'
if ! bash "${IMPORT_SUT}" indexes >/dev/null 2>&1; then
  pass "import indexes: landing problems fail the step"
else fail "import indexes: landing problems fail the step"; fi
teardown

# Test 9: unknown types still rejected on the import side too.
setup
if ! bash "${IMPORT_SUT}" bogus >/dev/null 2>&1; then
  pass "import: unknown resource type still rejected"
else fail "import: unknown resource type still rejected"; fi
teardown

echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All tests passed."
else
  echo "${FAILS} test(s) failed."
  exit 1
fi
