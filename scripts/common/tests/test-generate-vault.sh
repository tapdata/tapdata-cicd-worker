#!/usr/bin/env bash
# Local unit tests for generate-vault.sh
# (run: bash scripts/common/tests/test-generate-vault.sh)
#
# generate-vault.sh has no test coverage today, yet it runs on every deploy of
# every existing tenant. These tests pin the CURRENT behaviour of all four
# lookup priorities so that later changes (format 3 / lookup dedup) can be told
# apart from pre-existing breakage.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SCRIPT_DIR}/../../tapdata-deploy/generate-vault.sh"
FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); [[ -n "${2:-}" ]] && echo "        $2"; }

setup() {
  WORK="$(mktemp -d)"
  export REPO_ROOT="${WORK}"
  export PROJECT="testproj"
  EXPORT_DIR="${WORK}/${PROJECT}_tapdata_export"
  mkdir -p "${EXPORT_DIR}/Connection"
  export ALL_SECRETS='{}'
  export ALL_VARS='{}'
  OUT=""; RC=0
}
teardown() { rm -rf "${WORK}"; }

# Write a fake exported connection file. The real packages carry `json` as an
# embedded JSON *string*; generate-vault.sh handles both, we use the string form.
mkconn() {
  jq -n --arg name "$1" \
    '[{collectionName:"Connections", json:({name:$name}|tostring)}]' \
    > "${EXPORT_DIR}/Connection/${1}_Connection_Config.json"
}

run_sut() { OUT="$(bash "${SUT}" 2>&1)"; RC=$?; }

# Sorted, comma-joined key list of vault.json — asserting the whole set (rather
# than "contains") is what makes "must not write extra keys" discriminating.
vault_keys() { jq -S -r 'keys | join(",")' "${EXPORT_DIR}/vault.json" 2>/dev/null; }
vault_val()  { jq -r --arg k "$1" '.[$k] // empty' "${EXPORT_DIR}/vault.json" 2>/dev/null; }

# --- T7-3: format 1 (URI in Secrets) regression -----------------------------
# Discriminating: if a later change writes format-3 keys unconditionally, the
# key-set assertion goes red.
setup
mkconn "orders_mongo"
export ALL_SECRETS='{"ORDERS_MONGO_URI":"mongodb://u:p@h:27017/orders"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MONGO_URI" ]] \
   && [[ "$(vault_val ORDERS_MONGO_URI)" == "mongodb://u:p@h:27017/orders" ]]; then
  pass "format 1: only {CONN}_URI is written, value verbatim"
else fail "format 1: only {CONN}_URI is written, value verbatim" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-4: format 2 (URL + USER + PASSWORD) regression -----------------------
# Discriminating: reordering the priority chain breaks this one first.
setup
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_PG_URL":"pg.example.com:5432","ORDERS_PG_USER":"tapuser"}'
export ALL_SECRETS='{"ORDERS_PG_PASSWORD":"s3cr3t"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_PG_PASSWORD,ORDERS_PG_URL,ORDERS_PG_USER" ]] \
   && [[ "$(vault_val ORDERS_PG_URL)" == "pg.example.com:5432" ]] \
   && [[ "$(vault_val ORDERS_PG_USER)" == "tapuser" ]] \
   && [[ "$(vault_val ORDERS_PG_PASSWORD)" == "s3cr3t" ]]; then
  pass "format 2: three keys written verbatim"
else fail "format 2: three keys written verbatim" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-4a: priority 3, truncated prefix hit --------------------------------
# A_B_C_D falls back to the A_B_* keys, but the keys WRITTEN keep the original
# connection name. Zero coverage before this file; the lookup dedup (T6) will
# rewrite this level, so without this test that level changes unwatched.
setup
mkconn "a_b_c_d"
export ALL_VARS='{"A_B_URL":"prefix.example.com:3306","A_B_USER":"prefixuser"}'
export ALL_SECRETS='{"A_B_PASSWORD":"prefixpw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "A_B_C_D_PASSWORD,A_B_C_D_URL,A_B_C_D_USER" ]] \
   && [[ "$(vault_val A_B_C_D_URL)" == "prefix.example.com:3306" ]] \
   && [[ "$(vault_val A_B_C_D_USER)" == "prefixuser" ]] \
   && [[ "$(vault_val A_B_C_D_PASSWORD)" == "prefixpw" ]]; then
  pass "priority 3: truncated prefix hit, keys keep original connection name"
else fail "priority 3: truncated prefix hit, keys keep original connection name" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-4b: priority 4, DEFAULT_* hit ---------------------------------------
# Same shape as 4a but for the last level. Note this is the mirror image of the
# later format-3 case that pins DEFAULT_DSN must NOT fall back: here DEFAULT_URL
# MUST fall back.
setup
mkconn "orders_mysql"
export ALL_VARS='{"DEFAULT_URL":"default.example.com:3306","DEFAULT_USER":"defaultuser"}'
export ALL_SECRETS='{"DEFAULT_PASSWORD":"defaultpw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MYSQL_PASSWORD,ORDERS_MYSQL_URL,ORDERS_MYSQL_USER" ]] \
   && [[ "$(vault_val ORDERS_MYSQL_URL)" == "default.example.com:3306" ]] \
   && [[ "$(vault_val ORDERS_MYSQL_USER)" == "defaultuser" ]] \
   && [[ "$(vault_val ORDERS_MYSQL_PASSWORD)" == "defaultpw" ]]; then
  pass "priority 4: DEFAULT_* hit, keys keep original connection name"
else fail "priority 4: DEFAULT_* hit, keys keep original connection name" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- baseline: no match at all still fails loudly ---------------------------
# Not one of the plan's numbered cases, but it is the behaviour format 3 will
# insert itself in front of; pinning it makes the priority-chain edit visible.
setup
mkconn "orphan_conn"
run_sut
if [[ ${RC} -ne 0 ]] && [[ "${OUT}" == *"::error::"* ]]; then
  pass "no match: exits non-zero with an ::error:: annotation"
else fail "no match: exits non-zero with an ::error:: annotation" "rc=${RC}"; fi
teardown

echo
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
