#!/usr/bin/env bash
# Local unit tests for resolve-vault-transport.sh
# (run: bash scripts/common/tests/test-resolve-vault-transport.sh)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/../resolve-vault-transport.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

setup() {
  WORK="$(mktemp -d)"
  export DEPLOY_DIR="${WORK}/deploy"
  export VAULT_FILE="${WORK}/export/vault.json"
  mkdir -p "${WORK}/export"
  echo "ENCRYPTED" > "${VAULT_FILE}"
  export GITHUB_OUTPUT="${WORK}/gh_output"; : > "${GITHUB_OUTPUT}"
  export RUNNER_NAME="runner-A"
  unset FORCED_TRANSPORT UPLOAD_V4_OUTCOME UPLOAD_V3_OUTCOME 2>/dev/null || true
}
teardown() { rm -rf "${WORK}"; }
out() { grep "^$1=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-; }
pushed() { [[ -f "${DEPLOY_DIR}/vault-transport.enc" ]]; }

# Test 1: auto + v4 success => artifact-v4, no local push, runner recorded
setup
export FORCED_TRANSPORT=""; export UPLOAD_V4_OUTCOME="success"; export UPLOAD_V3_OUTCOME="skipped"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact-v4" ]] && ! pushed && [[ "$(out prep_runner)" == "runner-A" ]]; then
  pass "auto + v4 success => artifact-v4"
else fail "auto + v4 success => artifact-v4"; fi
teardown

# Test 2: auto + v4 failure + v3 success => artifact-v3, no local push
setup
export FORCED_TRANSPORT=""; export UPLOAD_V4_OUTCOME="failure"; export UPLOAD_V3_OUTCOME="success"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact-v3" ]] && ! pushed; then
  pass "auto + v4 fail + v3 success => artifact-v3"
else fail "auto + v4 fail + v3 success => artifact-v3"; fi
teardown

# Test 3: auto + v4 failure + v3 failure => local + push (canonical old-GHES case)
setup
export FORCED_TRANSPORT=""; export UPLOAD_V4_OUTCOME="failure"; export UPLOAD_V3_OUTCOME="failure"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "local" ]] && pushed; then
  pass "auto + both fail => local + push"
else fail "auto + both fail => local + push"; fi
teardown

# Test 4: forced local (uploads skipped) => local + push
setup
export FORCED_TRANSPORT="local"; export UPLOAD_V4_OUTCOME="skipped"; export UPLOAD_V3_OUTCOME="skipped"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "local" ]] && pushed; then
  pass "forced local => local + push"
else fail "forced local => local + push"; fi
teardown

# Test 5: forced artifact + v4 success => artifact-v4, no push
setup
export FORCED_TRANSPORT="artifact"; export UPLOAD_V4_OUTCOME="success"; export UPLOAD_V3_OUTCOME="skipped"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact-v4" ]] && ! pushed; then
  pass "forced artifact + v4 success => artifact-v4"
else fail "forced artifact + v4 success => artifact-v4"; fi
teardown

# Test 6: forced artifact + v4 fail + v3 success => artifact-v3, no push
setup
export FORCED_TRANSPORT="artifact"; export UPLOAD_V4_OUTCOME="failure"; export UPLOAD_V3_OUTCOME="success"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact-v3" ]] && ! pushed; then
  pass "forced artifact + v3 success => artifact-v3"
else fail "forced artifact + v3 success => artifact-v3"; fi
teardown

# Test 7: forced artifact + both fail => exit 1, NO local fallback, no push
setup
export FORCED_TRANSPORT="artifact"; export UPLOAD_V4_OUTCOME="failure"; export UPLOAD_V3_OUTCOME="failure"
if bash "${SUT}" >/dev/null 2>&1; then fail "forced artifact + both fail should exit 1"
elif pushed; then fail "forced artifact + both fail must not push local file"
else pass "forced artifact + both fail => exit 1, no push"; fi
teardown

# Test 8: invalid value => exit 1
setup
export FORCED_TRANSPORT="bogus"; export UPLOAD_V4_OUTCOME="success"; export UPLOAD_V3_OUTCOME="skipped"
if bash "${SUT}" >/dev/null 2>&1; then fail "invalid VAULT_TRANSPORT should exit 1"
else pass "invalid VAULT_TRANSPORT exits 1"; fi
teardown

echo
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
