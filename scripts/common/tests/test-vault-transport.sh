#!/usr/bin/env bash
# Local unit tests for vault-transport.sh (run: bash scripts/common/tests/test-vault-transport.sh)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/../vault-transport.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

setup() {
  WORK="$(mktemp -d)"
  export DEPLOY_DIR="${WORK}/deploy"
  export VAULT_FILE="${WORK}/export/vault.json"
  mkdir -p "${WORK}/export"
  unset PREP_RUNNER RUNNER_NAME 2>/dev/null || true
}
teardown() { rm -rf "${WORK}"; }

# Test 1: push copies vault to transport file
setup
echo "ENCRYPTED-BYTES" > "${VAULT_FILE}"
if bash "${SUT}" push >/dev/null 2>&1 \
   && [[ -f "${DEPLOY_DIR}/vault-transport.enc" ]] \
   && [[ "$(cat "${DEPLOY_DIR}/vault-transport.enc")" == "ENCRYPTED-BYTES" ]]; then
  pass "push writes vault-transport.enc"
else fail "push writes vault-transport.enc"; fi
teardown

# Test 2: push fails when vault file missing
setup
if bash "${SUT}" push >/dev/null 2>&1; then fail "push should fail when VAULT_FILE missing"
else pass "push fails when VAULT_FILE missing"; fi
teardown

# Test 3: pull on same runner restores vault.json
setup
mkdir -p "${DEPLOY_DIR}"
echo "ENCRYPTED-BYTES" > "${DEPLOY_DIR}/vault-transport.enc"
export PREP_RUNNER="runner-A"; export RUNNER_NAME="runner-A"
if bash "${SUT}" pull >/dev/null 2>&1 \
   && [[ -f "${VAULT_FILE}" ]] \
   && [[ "$(cat "${VAULT_FILE}")" == "ENCRYPTED-BYTES" ]]; then
  pass "pull restores vault.json on same runner"
else fail "pull restores vault.json on same runner"; fi
teardown

# Test 4: pull fails on runner mismatch
setup
mkdir -p "${DEPLOY_DIR}"; echo "X" > "${DEPLOY_DIR}/vault-transport.enc"
export PREP_RUNNER="runner-A"; export RUNNER_NAME="runner-B"
if bash "${SUT}" pull >/dev/null 2>&1; then fail "pull should fail on runner mismatch"
else pass "pull fails on runner mismatch"; fi
teardown

# Test 5: pull fails when transport file missing (same runner)
setup
mkdir -p "${DEPLOY_DIR}"
export PREP_RUNNER="runner-A"; export RUNNER_NAME="runner-A"
if bash "${SUT}" pull >/dev/null 2>&1; then fail "pull should fail when transport file missing"
else pass "pull fails when transport file missing"; fi
teardown

# Test 6: unknown action fails
setup
if bash "${SUT}" frobnicate >/dev/null 2>&1; then fail "unknown action should fail"
else pass "unknown action fails"; fi
teardown

echo
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
