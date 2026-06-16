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
  unset FORCED_TRANSPORT UPLOAD_OUTCOME 2>/dev/null || true
}
teardown() { rm -rf "${WORK}"; }
out() { grep "^$1=" "${GITHUB_OUTPUT}" | tail -1 | cut -d= -f2-; }

# Test 1: auto + upload success => artifact, no local push, runner recorded
setup
export FORCED_TRANSPORT=""; export UPLOAD_OUTCOME="success"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact" ]] \
   && [[ ! -f "${DEPLOY_DIR}/vault-transport.enc" ]] \
   && [[ "$(out prep_runner)" == "runner-A" ]]; then
  pass "auto+success => artifact"
else fail "auto+success => artifact"; fi
teardown

# Test 2: auto + upload failure => local + push performed
setup
export FORCED_TRANSPORT=""; export UPLOAD_OUTCOME="failure"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "local" ]] && [[ -f "${DEPLOY_DIR}/vault-transport.enc" ]]; then
  pass "auto+failure => local + push"
else fail "auto+failure => local + push"; fi
teardown

# Test 2b: auto + upload skipped (canonical GHES case) => local + push
setup
export FORCED_TRANSPORT=""; export UPLOAD_OUTCOME="skipped"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "local" ]] && [[ -f "${DEPLOY_DIR}/vault-transport.enc" ]]; then
  pass "auto+skipped => local + push"
else fail "auto+skipped => local + push"; fi
teardown

# Test 3: forced local (upload skipped) => local + push
setup
export FORCED_TRANSPORT="local"; export UPLOAD_OUTCOME="skipped"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "local" ]] && [[ -f "${DEPLOY_DIR}/vault-transport.enc" ]]; then
  pass "forced local => local + push"
else fail "forced local => local + push"; fi
teardown

# Test 4: forced artifact (even if upload failed) => artifact, no push
setup
export FORCED_TRANSPORT="artifact"; export UPLOAD_OUTCOME="failure"
bash "${SUT}" >/dev/null 2>&1
if [[ "$(out vault_transport)" == "artifact" ]] && [[ ! -f "${DEPLOY_DIR}/vault-transport.enc" ]]; then
  pass "forced artifact => artifact, no push"
else fail "forced artifact => artifact, no push"; fi
teardown

# Test 5: invalid value => exit 1
setup
export FORCED_TRANSPORT="bogus"; export UPLOAD_OUTCOME="success"
if bash "${SUT}" >/dev/null 2>&1; then fail "invalid VAULT_TRANSPORT should exit 1"
else pass "invalid VAULT_TRANSPORT exits 1"; fi
teardown

echo
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
