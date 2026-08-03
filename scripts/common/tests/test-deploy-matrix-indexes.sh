#!/usr/bin/env bash
# Local unit tests for the serving-index leg in the deploy matrix (TAP-12057 · P4-3)
# (run: bash scripts/common/tests/test-deploy-matrix-indexes.sh)
#
# The "Build Deploy Matrix" step lives inline in tapdata-deploy.yml, so these tests lift
# that script out of the workflow, substitute the has_changes expressions, and run it.
# What they pin:
#   * indexes deploy AFTER apis. Declarations ride on the Module -- deploying indexes first
#     would create them from a Module the target environment has not received yet.
#   * the leg reuses apis-export.tar (compress-files.sh tars the whole export dir).
#   * no planned indexes => no leg at all, so the run graph stays free of no-op nodes.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../../../.github/workflows/tapdata-deploy.yml"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# Lift the step's `run:` block out of the workflow and replace each
# ${{ steps.preview_X.outputs.has_changes }} with the value of env var X.
extract_matrix_script() {
  python3 - "$WORKFLOW" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for step in doc['jobs']['preview-all']['steps']:
    if step.get('id') == 'build_matrix':
        script = step['run']
        break
else:
    raise SystemExit('build_matrix step not found')
script = re.sub(r'\$\{\{\s*steps\.preview_(\w+)\.outputs\.has_changes\s*\}\}',
                lambda m: '${%s:-false}' % m.group(1).upper(), script)
print(script)
PY
}

run_matrix() {
  local work; work="$(mktemp -d)"
  extract_matrix_script > "${work}/build_matrix.sh"
  GITHUB_OUTPUT="${work}/out" bash "${work}/build_matrix.sh" >/dev/null 2>&1
  grep '^deploy_matrix=' "${work}/out" | tail -1 | cut -d= -f2-
  rm -rf "${work}"
}

# Test 1: everything changed => indexes is the last leg, after apis.
MATRIX=$(CONNECTIONS=true MIGRATE_TASKS=true SYNC_TASKS=true APIS=true INDEXES=true run_matrix)
KEYS=$(jq -r '[.include[].key] | join(",")' <<<"${MATRIX}")
if [[ "${KEYS}" == "connections,migrate-tasks,sync-tasks,apis,indexes" ]]; then
  pass "indexes deploys last, after apis"
else fail "indexes deploys last, after apis (got: ${KEYS})"; fi

# Test 2: the order field drives the run-graph sort, so apis must sort before indexes.
APIS_ORDER=$(jq -r '.include[] | select(.key=="apis") | .order' <<<"${MATRIX}")
IDX_ORDER=$(jq -r '.include[] | select(.key=="indexes") | .order' <<<"${MATRIX}")
if [[ -n "${IDX_ORDER}" && "${IDX_ORDER}" -gt "${APIS_ORDER}" ]]; then
  pass "indexes order (${IDX_ORDER}) sorts after apis (${APIS_ORDER})"
else fail "indexes order sorts after apis (apis=${APIS_ORDER} indexes=${IDX_ORDER})"; fi

# Test 3: the leg reuses the API archive and calls the indexes import arg.
ENTRY=$(jq -c '.include[] | select(.key=="indexes")' <<<"${MATRIX}")
if [[ "$(jq -r '.archive' <<<"${ENTRY}")" == "apis-export.tar" \
   && "$(jq -r '.import_arg' <<<"${ENTRY}")" == "indexes" \
   && "$(jq -r '.label' <<<"${ENTRY}")" == "Serving Indexes" ]]; then
  pass "indexes leg: apis-export.tar + import_arg=indexes + labelled"
else fail "indexes leg: apis-export.tar + import_arg=indexes + labelled (got: ${ENTRY})"; fi

# Test 4: nothing to create => no leg (no greyed-out no-op node in the run graph).
MATRIX_NONE=$(CONNECTIONS=false MIGRATE_TASKS=false SYNC_TASKS=false APIS=false INDEXES=false run_matrix)
if [[ "$(jq -r '.include | length' <<<"${MATRIX_NONE}")" == "0" ]]; then
  pass "no planned indexes => no leg"
else fail "no planned indexes => no leg (got: ${MATRIX_NONE})"; fi

# Test 5: indexes can deploy on their own -- an index deleted in the target环境 must be
# repairable even when the API itself is unchanged (TM's index leg ignores Module diff).
MATRIX_ONLY=$(CONNECTIONS=false MIGRATE_TASKS=false SYNC_TASKS=false APIS=false INDEXES=true run_matrix)
if [[ "$(jq -r '[.include[].key] | join(",")' <<<"${MATRIX_ONLY}")" == "indexes" ]]; then
  pass "indexes-only run is a valid matrix"
else fail "indexes-only run is a valid matrix (got: ${MATRIX_ONLY})"; fi

# Test 6: rollback must not grow an indexes leg -- rolling back never drops or creates
# indexes; the resulting drift is by design and handled by the reconciliation report.
ROLLBACK="${SCRIPT_DIR}/../../../.github/workflows/tapdata-rollback.yml"
if ! grep -qi "indexes" "${ROLLBACK}"; then
  pass "rollback workflow has no indexes leg"
else fail "rollback workflow has no indexes leg"; fi

echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All tests passed."
else
  echo "${FAILS} test(s) failed."
  exit 1
fi
