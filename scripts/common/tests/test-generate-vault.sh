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
FAILS=0; REG_FAILS=0; DSN_FAILS=0; GROUP="reg"
pass() { echo "  PASS: $1"; }
fail() {
  echo "  FAIL: $1"; FAILS=$((FAILS+1))
  if [[ "${GROUP}" == "reg" ]]; then REG_FAILS=$((REG_FAILS+1)); else DSN_FAILS=$((DSN_FAILS+1)); fi
  [[ -n "${2:-}" ]] && echo "        $2"
  return 0
}
has()    { [[ "${OUT}" == *"$1"* ]]; }
lacks()  { [[ "${OUT}" != *"$1"* ]]; }

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

# ============================================================================
# Format 3 ({CONN}_DSN in Variables + {CONN}_PASSWORD in Secrets), ADR-0036.
#
# These are RED until T2 implements the _DSN lookup. That is the point: they
# are written first so the implementation has something to turn green, and so
# a half-done implementation cannot look finished.
#
# All DSN literals are taken verbatim from the ADR's L1..L12 table. Both sides
# (this script and ResourceHandlerVaultTest) must quote that one table rather
# than invent their own strings — otherwise bash and Java drift apart and each
# side's tests stay green while disagreeing about the same DSN.
#
# The three marker phrases below are the user-visible contract this suite pins.
# ADR-0036 requires only "names the connection and the reason, never echoes the
# DSN" (D6); the exact wording is chosen here and must match the implementation.
# ============================================================================
GROUP="dsn"
ERR_DSN_PASSWORD="must not contain a password"
WARN_NO_DATABASE="does not carry a database name"
WARN_NO_PASSWORD="no password configured"

L1="user@localhost:3306/test"
L2="jdbc:mysql://user@localhost:3306/test"
L3="mysql://user@localhost:3306/test"
L5="mongodb://tapuser:@h:27017/orders?authSource=admin"
L8="user:realpw@localhost:3306/test"
L9="mongodb://u:realpw@h:27017/db"
L10="localhost:3306"

echo "--- format 3 (expected RED until T2) ---"

# --- T7-1: DSN + PASSWORD both written, values verbatim ---------------------
# Discriminating: without the T2 lookup the script falls through to "no match"
# and exits 1, so this goes red on rc alone.
setup
mkconn "orders_mongo"
export ALL_VARS="$(jq -n --arg d "${L5}" '{ORDERS_MONGO_DSN:$d}')"
export ALL_SECRETS='{"ORDERS_MONGO_PASSWORD":"s3cr3t"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MONGO_DSN,ORDERS_MONGO_PASSWORD" ]] \
   && [[ "$(vault_val ORDERS_MONGO_DSN)" == "${L5}" ]] \
   && [[ "$(vault_val ORDERS_MONGO_PASSWORD)" == "s3cr3t" ]]; then
  pass "T7-1 format 3: _DSN + _PASSWORD written, values verbatim"
else fail "T7-1 format 3: _DSN + _PASSWORD written, values verbatim" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-2: a DSN carrying a non-empty password is an ERROR ------------------
# Discriminating: assert the MESSAGE, not just the exit code. Today the script
# already exits non-zero (generic "Missing config"), so an rc-only assertion
# would pass for the wrong reason and keep passing if the check were dropped.
setup
mkconn "orders_mongo"
export ALL_VARS="$(jq -n --arg d "${L9}" '{ORDERS_MONGO_DSN:$d}')"
run_sut
if [[ ${RC} -ne 0 ]] && has "::error::" && has "${ERR_DSN_PASSWORD}" && has "ORDERS_MONGO"; then
  pass "T7-2 DSN with a password: errors and names the reason"
else fail "T7-2 DSN with a password: errors and names the reason" "rc=${RC}"; fi
teardown

# --- T7-5: no {CONN}_PASSWORD anywhere is legal (a password-less connection) -
# Three assertions, each blocking one direction: rc catches "changed back to an
# error", the warning catches "passed silently", the key set catches "wrote an
# empty _PASSWORD to tidy up". The middle one matters most — that warning is the
# only thing a person who typo'd the key name will ever see.
setup
mkconn "orders_pg"
export ALL_VARS="$(jq -n --arg d "${L1}" '{ORDERS_PG_DSN:$d}')"
export ALL_SECRETS='{}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_PG_DSN" ]] \
   && has "::warning::" && has "${WARN_NO_PASSWORD}" && has "ORDERS_PG_PASSWORD"; then
  pass "T7-5 no password: rc=0, only _DSN written, warning names the key verbatim"
else fail "T7-5 no password: rc=0, only _DSN written, warning names the key verbatim" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-6: DEFAULT_DSN must NOT fall back -----------------------------------
# Green today (nothing looks up _DSN at all); it exists to stay green after T2.
# Mirror image of T7-4b: there DEFAULT_URL MUST fall back, here DEFAULT_DSN must
# not. Letting it fall back points every connection at one database.
setup
mkconn "orders_mysql"
export ALL_VARS='{"DEFAULT_DSN":"user@default-host:3306/defaultdb","ORDERS_MYSQL_URL":"mysql.example.com:3306","ORDERS_MYSQL_USER":"tapuser"}'
export ALL_SECRETS='{"ORDERS_MYSQL_PASSWORD":"pw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MYSQL_PASSWORD,ORDERS_MYSQL_URL,ORDERS_MYSQL_USER" ]]; then
  pass "T7-6 DEFAULT_DSN does not fall back; format 2 still wins"
else fail "T7-6 DEFAULT_DSN does not fall back; format 2 still wins" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-6a: coexistence window — _DSN beats _URI ----------------------------
# The migration guide says "add the new key, then remove the old one", so this
# state is unavoidable. If DSN lost, the operator would add the key, redeploy,
# see green, and still be running format 1.
setup
mkconn "orders_mongo"
export ALL_SECRETS='{"ORDERS_MONGO_URI":"mongodb://u:p@old-host:27017/olddb","ORDERS_MONGO_PASSWORD":"s3cr3t"}'
export ALL_VARS='{"ORDERS_MONGO_DSN":"mongodb://tapuser:@new-host:27017/newdb"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MONGO_DSN,ORDERS_MONGO_PASSWORD" ]] \
   && [[ "$(vault_val ORDERS_MONGO_DSN)" == "mongodb://tapuser:@new-host:27017/newdb" ]]; then
  pass "T7-6a coexistence: _DSN wins over _URI, no _URI key emitted"
else fail "T7-6a coexistence: _DSN wins over _URI, no _URI key emitted" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-6b: the three JDBC forms travel verbatim ----------------------------
# Per ADR-0036 D7 the worker does NOT normalise — it copies. What it must do is
# UNDERSTAND all three forms well enough to check them: a checker that only
# knows the bare form would report "no database" for L2 and L3. That second
# assertion is the real gate here.
for _form in "${L1}" "${L2}" "${L3}"; do
  setup
  mkconn "orders_pg"
  export ALL_VARS="$(jq -n --arg d "${_form}" '{ORDERS_PG_DSN:$d}')"
  export ALL_SECRETS='{"ORDERS_PG_PASSWORD":"pw"}'
  run_sut
  if [[ ${RC} -eq 0 ]] \
     && [[ "$(vault_val ORDERS_PG_DSN)" == "${_form}" ]] \
     && lacks "${WARN_NO_DATABASE}"; then
    pass "T7-6b form travels verbatim, no false 'no database' warning: ${_form}"
  else fail "T7-6b form travels verbatim, no false 'no database' warning: ${_form}" "rc=${RC} got=$(vault_val ORDERS_PG_DSN)"; fi
  teardown
done

# --- T7-6c: a DSN without a database name warns but does not fail -----------
setup
mkconn "orders_pg"
export ALL_VARS="$(jq -n --arg d "${L10}" '{ORDERS_PG_DSN:$d}')"
export ALL_SECRETS='{"ORDERS_PG_PASSWORD":"pw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_val ORDERS_PG_DSN)" == "${L10}" ]] \
   && has "::warning::" && has "${WARN_NO_DATABASE}"; then
  pass "T7-6c no database name: rc=0, _DSN still written, warning raised"
else fail "T7-6c no database name: rc=0, _DSN still written, warning raised" "rc=${RC}"; fi
teardown

# --- T7-6d: the password half DOES fall back to DEFAULT_PASSWORD ------------
# This is the shape a tenant currently matching via DEFAULT_* lands in when they
# migrate one connection. Complementary to T7-5: there no password source exists
# at all (warn); here one does (use it silently). An implementation that copies
# the DSN half's exact-name-only rule goes red here — and what it goes red on is
# precisely the "deploy is green, breaks on the next credential rotation" case.
setup
mkconn "orders_pg"
export ALL_VARS="$(jq -n --arg d "${L1}" '{ORDERS_PG_DSN:$d}')"
export ALL_SECRETS='{"DEFAULT_PASSWORD":"defaultpw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_PG_DSN,ORDERS_PG_PASSWORD" ]] \
   && [[ "$(vault_val ORDERS_PG_PASSWORD)" == "defaultpw" ]] \
   && lacks "${WARN_NO_PASSWORD}"; then
  pass "T7-6d password falls back to DEFAULT_PASSWORD, no no-password warning"
else fail "T7-6d password falls back to DEFAULT_PASSWORD, no no-password warning" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- T7-6e: the error must not echo the DSN ---------------------------------
# T7-2 only asserts the message names the reason — an implementation that prints
# the whole DSN would still pass it. GitHub masks Secrets but NOT Variables, so
# echoing here writes the password permanently into a log any user with read
# access can download: the check would become the leak amplifier.
setup
mkconn "orders_pg"
export ALL_VARS="$(jq -n --arg d "${L8}" '{ORDERS_PG_DSN:$d}')"
run_sut
if [[ ${RC} -ne 0 ]] && has "${ERR_DSN_PASSWORD}" && lacks "realpw"; then
  pass "T7-6e error names the reason without echoing the DSN"
else fail "T7-6e error names the reason without echoing the DSN" "rc=${RC}"; fi
teardown

# --- double-prefixed DSN carrying a password --------------------------------
# T7-2 uses the mongodb form and T7-6e the bare form; neither covers "jdbc:" AND
# a scheme together. A password check that forgets to strip prefixes before
# looking for the userinfo sees authority "jdbc:" -- no "@" -- and reports the
# DSN as clean, which is the one failure mode where the check silently stops
# protecting anything.
setup
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_PG_DSN":"jdbc:mysql://user:realpw@localhost:3306/test"}'
run_sut
if [[ ${RC} -ne 0 ]] && has "${ERR_DSN_PASSWORD}" && lacks "realpw"; then
  pass "double-prefixed DSN with a password is still rejected"
else fail "double-prefixed DSN with a password is still rejected" "rc=${RC}"; fi
teardown

# --- L6 / L7: MongoDB shapes that must not trip the "no database" check ------
# Not in the plan's worker table (they are listed TM-side), but the worker runs
# its checks on them too, and a false "no database" warning here would fire on
# every replica-set connection HA has -- i.e. on the most common shape, every
# deploy. Seed lists and mongodb+srv also break naive parsing in different ways.
setup
mkconn "orders_mongo"
export ALL_VARS='{"ORDERS_MONGO_DSN":"mongodb://tapuser:@h1:27017,h2:27017/orders?replicaSet=rs0"}'
export ALL_SECRETS='{"ORDERS_MONGO_PASSWORD":"pw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_val ORDERS_MONGO_DSN)" == "mongodb://tapuser:@h1:27017,h2:27017/orders?replicaSet=rs0" ]] \
   && lacks "${WARN_NO_DATABASE}"; then
  pass "L6 replica-set seed list: verbatim, no false 'no database' warning"
else fail "L6 replica-set seed list: verbatim, no false 'no database' warning" "rc=${RC}"; fi
teardown

setup
mkconn "orders_mongo"
export ALL_VARS='{"ORDERS_MONGO_DSN":"mongodb+srv://tapuser:@cluster.example.net/orders"}'
export ALL_SECRETS='{"ORDERS_MONGO_PASSWORD":"pw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_val ORDERS_MONGO_DSN)" == "mongodb+srv://tapuser:@cluster.example.net/orders" ]] \
   && lacks "${WARN_NO_DATABASE}"; then
  pass "L7 mongodb+srv (no port, single host): verbatim, no false warning"
else fail "L7 mongodb+srv (no port, single host): verbatim, no false warning" "rc=${RC}"; fi
teardown

# --- mixed formats in one repo ----------------------------------------------
# The migration is per-connection, so "some connections on format 3, the rest
# on the old ones" is the normal state for as long as it takes -- not an edge
# case. Also the only test here with more than one connection, so it is what
# catches per-iteration state leaking between connections.
setup
mkconn "orders_mongo"
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_MONGO_DSN":"mongodb://tapuser:@h:27017/orders","ORDERS_PG_URL":"pg.example.com:5432","ORDERS_PG_USER":"pguser"}'
export ALL_SECRETS='{"ORDERS_MONGO_PASSWORD":"mpw","ORDERS_PG_PASSWORD":"ppw"}'
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_MONGO_DSN,ORDERS_MONGO_PASSWORD,ORDERS_PG_PASSWORD,ORDERS_PG_URL,ORDERS_PG_USER" ]] \
   && [[ "$(vault_val ORDERS_PG_URL)" == "pg.example.com:5432" ]] \
   && [[ "$(vault_val ORDERS_MONGO_PASSWORD)" == "mpw" ]] \
   && [[ "$(vault_val ORDERS_PG_PASSWORD)" == "ppw" ]]; then
  pass "mixed: format 3 and format 2 connections coexist in one vault.json"
else fail "mixed: format 3 and format 2 connections coexist in one vault.json" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# --- flattening edge cases (T6) ---------------------------------------------
# The lookup tables are built by flattening both blobs once. These pin the three
# ways that flattening can silently corrupt them. All three are regressions, not
# format-3 features: they describe how EVERY lookup behaves.
GROUP="reg"

# A secret value containing newlines. PEM keys held as secrets are the obvious
# real case. A line-based reader would truncate the value AND read its remaining
# lines as further KEY=VALUE pairs, inventing keys nobody configured.
setup
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_PG_URL":"pg.example.com:5432","ORDERS_PG_USER":"tapuser"}'
export ALL_SECRETS="$(jq -n --arg p 'line1
line2
line3' '{ORDERS_PG_PASSWORD:$p, DECOY:"x"}')"
run_sut
if [[ ${RC} -eq 0 ]] \
   && [[ "$(vault_keys)" == "ORDERS_PG_PASSWORD,ORDERS_PG_URL,ORDERS_PG_USER" ]] \
   && [[ "$(vault_val ORDERS_PG_PASSWORD)" == 'line1
line2
line3' ]]; then
  pass "multi-line secret value survives flattening intact"
else fail "multi-line secret value survives flattening intact" "rc=${RC} keys=$(vault_keys)"; fi
teardown

# A value containing "=". Keys are split on the FIRST "=", so the value keeps
# every later one; splitting on the last would silently truncate it.
setup
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_PG_URL":"pg.example.com:5432","ORDERS_PG_USER":"tapuser"}'
export ALL_SECRETS='{"ORDERS_PG_PASSWORD":"a=b=c"}'
run_sut
if [[ ${RC} -eq 0 ]] && [[ "$(vault_val ORDERS_PG_PASSWORD)" == "a=b=c" ]]; then
  pass "secret value containing '=' survives flattening"
else fail "secret value containing '=' survives flattening" "rc=${RC} got=$(vault_val ORDERS_PG_PASSWORD)"; fi
teardown

# One blob empty. A repo using only Secrets (or only Variables) is ordinary, and
# an empty associative array is unbound under `set -u`: ${#MAP[@]} aborts the
# whole script while ${MAP[$k]-} is fine. Caught during T6 by the format-1 test,
# which only covers it by accident -- this one says so in its name.
setup
mkconn "orders_mongo"
export ALL_SECRETS='{"ORDERS_MONGO_URI":"mongodb://u:p@h:27017/orders"}'
export ALL_VARS='{}'
run_sut
if [[ ${RC} -eq 0 ]] && [[ "$(vault_keys)" == "ORDERS_MONGO_URI" ]]; then
  pass "empty ALL_VARS: lookup tables tolerate an empty blob"
else fail "empty ALL_VARS: lookup tables tolerate an empty blob" "rc=${RC}"; fi
teardown

setup
mkconn "orders_pg"
export ALL_VARS='{"ORDERS_PG_DSN":"user@localhost:3306/test"}'
export ALL_SECRETS='{}'
run_sut
if [[ ${RC} -eq 0 ]] && [[ "$(vault_keys)" == "ORDERS_PG_DSN" ]]; then
  pass "empty ALL_SECRETS: lookup tables tolerate an empty blob"
else fail "empty ALL_SECRETS: lookup tables tolerate an empty blob" "rc=${RC}"; fi
teardown

# Malformed JSON must fail with a statement of which blob is bad, not with a raw
# jq error from whichever lookup happened to run first.
setup
mkconn "orders_pg"
export ALL_SECRETS='{not json'
run_sut
if [[ ${RC} -ne 0 ]] && has "ALL_SECRETS is not valid JSON"; then
  pass "malformed ALL_SECRETS names the offending blob"
else fail "malformed ALL_SECRETS names the offending blob" "rc=${RC}"; fi
teardown

echo
if [[ ${REG_FAILS} -ne 0 ]]; then
  echo "REGRESSION BROKEN: ${REG_FAILS} test(s) pinning EXISTING behaviour failed."
  echo "  Stop. That is a change to what every current tenant's deploy already does."
fi
if [[ ${DSN_FAILS} -ne 0 ]]; then
  echo "format 3: ${DSN_FAILS} test(s) failing — expected until T2 implements the _DSN lookup."
fi
if [[ ${FAILS} -eq 0 ]]; then echo "ALL TESTS PASSED"; exit 0; else echo "${FAILS} TEST(S) FAILED"; exit 1; fi
