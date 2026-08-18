#!/usr/bin/env bash
# Generate vault.json with connection secrets from GitHub Secrets and Variables
# Required env vars: PROJECT, ALL_SECRETS, ALL_VARS
# ALL_SECRETS comes from ${{ toJSON(secrets) }}
# ALL_VARS comes from ${{ toJSON(vars) }}
# Lookup priority (stop at first match):
#   1. {CONNECTION_NAME}_DSN (Variables) + {CONNECTION_NAME}_PASSWORD (Secrets)
#      The DSN carries host/port/database/user with an EMPTY password position.
#      Scope is deliberately asymmetric (ADR-0036 D4): the _DSN half matches the
#      exact connection name only -- it carries the identity of a database, so a
#      fallback means connecting to the wrong one. The _PASSWORD half falls back
#      like format 2 (exact -> prefix -> DEFAULT): a fallback there just yields
#      the same password as before the migration.
#   2. {CONNECTION_NAME}_URI in Secrets
#   3. {CONNECTION_NAME}_URL (Variables) + {CONNECTION_NAME}_USER (Variables) + {CONNECTION_NAME}_PASSWORD (Secrets)
#   4. Truncate name to prefix before the 2nd underscore (e.g. A_B_C_D -> A_B),
#      then {PREFIX}_URL (Variables) + {PREFIX}_USER (Variables) + {PREFIX}_PASSWORD (Secrets)
#   5. DEFAULT_URL (Variables) + DEFAULT_USER (Variables) + DEFAULT_PASSWORD (Secrets)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

echo "=== Generating vault.json ==="

# Validate required env vars
if [[ -z "${PROJECT:-}" ]]; then
  echo "::error::PROJECT is not set or empty"
  exit 1
fi

if [[ -z "${ALL_SECRETS:-}" ]]; then
  echo "::error::ALL_SECRETS is not set or empty"
  exit 1
fi

if [[ -z "${ALL_VARS:-}" ]]; then
  echo "::error::ALL_VARS is not set or empty"
  exit 1
fi

# Associative arrays (below) need bash 4+. macOS still ships bash 3.2 as
# /bin/bash, so without this the failure would be a confusing syntax error
# rather than a statement of what is missing. CI runners are bash 5.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "::error::bash 4+ is required (associative arrays); this shell is ${BASH_VERSION}"
  exit 1
fi

# Both blobs are parsed exactly once (below), so a malformed one must be caught
# here. Previously the first lookup would fail with a raw jq error; a silently
# empty map would instead make every connection report "no match".
if ! printf '%s' "${ALL_SECRETS}" | jq -e . >/dev/null 2>&1; then
  echo "::error::ALL_SECRETS is not valid JSON"
  exit 1
fi
if ! printf '%s' "${ALL_VARS}" | jq -e . >/dev/null 2>&1; then
  echo "::error::ALL_VARS is not valid JSON"
  exit 1
fi

# Locate connection files directory
EXPORT_DIR="${REPO_ROOT}/${PROJECT}_tapdata_export"
CONNECTIONS_DIR="${EXPORT_DIR}/Connection"

if [[ ! -d "${CONNECTIONS_DIR}" ]]; then
  echo "::error::Connections directory not found: ${CONNECTIONS_DIR}"
  exit 1
fi

# Scan all *Connection_Config.json files and extract connection names
# Each file is a JSON array; extract name where collectionName == "Connections"
CONNECTION_NAMES=()
while IFS= read -r file; do
  while IFS= read -r name; do
    if [[ -n "${name}" ]]; then
      CONN_NAME_UPPER=$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')
      CONNECTION_NAMES+=("${CONN_NAME_UPPER}")
      echo "Found connection: ${name} -> ${CONN_NAME_UPPER} (from ${file})"
    fi
  done < <(jq -r '.[] | select(.collectionName == "Connections") | if (.json | type) == "string" then (.json | fromjson | .name // empty) else (.json | .name // empty) end' "${file}")
done < <(find "${CONNECTIONS_DIR}" -name "*Connection_Config.json" -type f)

if [[ ${#CONNECTION_NAMES[@]} -eq 0 ]]; then
  echo "::warning::No connection files found in ${CONNECTIONS_DIR}"
  echo "{}" > "${EXPORT_DIR}/vault.json"
  echo "=== Generated empty vault.json ==="
  exit 0
fi

# Build vault.json from secrets and variables
# Lookup priority (stop at first match):
#   1. {NAME}_DSN (Variables, exact name only) + {NAME}_PASSWORD (Secrets, falls back)
#   2. {NAME}_URI in Secrets
#   3. {NAME}_URL (Variables) + {NAME}_USER (Variables) + {NAME}_PASSWORD (Secrets)
#   4. Truncate to prefix (A_B_C_D -> A_B), then {PREFIX}_URL + {PREFIX}_USER + {PREFIX}_PASSWORD
#   5. DEFAULT_URL (Variables) + DEFAULT_USER (Variables) + DEFAULT_PASSWORD (Secrets)
VAULT_JSON="{}"

# Extract prefix before the second underscore: A_B_C_D -> A_B
get_prefix() {
  local name="$1"
  local part1 part2
  part1=$(echo "${name}" | cut -d'_' -f1)
  part2=$(echo "${name}" | cut -d'_' -f2)
  local parts_count
  parts_count=$(echo "${name}" | awk -F'_' '{print NF}')
  if [[ "${parts_count}" -ge 3 && -n "${part1}" && -n "${part2}" ]]; then
    echo "${part1}_${part2}"
  else
    echo ""
  fi
}

# --- Flatten both blobs once, then look everything up in memory -------------
# Every lookup used to re-parse the entire JSON. With five priorities that is up
# to ~11 full parses per connection, once per connection in the repo. Now it is
# two parses for the whole run.
#
# NUL-delimited, not line-delimited: secret VALUES may legitimately contain
# newlines -- a PEM key held in a secret is the obvious case -- and a line-based
# reader would both truncate such a value and read its remaining lines as
# further KEY=VALUE entries, inventing keys that were never configured. Keys are
# split on the FIRST "=", so values containing "=" survive intact.
declare -A SECRETS_MAP
declare -A VARS_MAP
SECRETS_COUNT=0
VARS_COUNT=0
FLATTEN_JQ='to_entries[] | "\(.key)=\(.value|tostring)" + "\u0000"'

while IFS= read -r -d '' _entry; do
  SECRETS_MAP["${_entry%%=*}"]="${_entry#*=}"
  SECRETS_COUNT=$((SECRETS_COUNT + 1))
done < <(printf '%s' "${ALL_SECRETS}" | jq -j "${FLATTEN_JQ}")

while IFS= read -r -d '' _entry; do
  VARS_MAP["${_entry%%=*}"]="${_entry#*=}"
  VARS_COUNT=$((VARS_COUNT + 1))
done < <(printf '%s' "${ALL_VARS}" | jq -j "${FLATTEN_JQ}")

echo "Loaded ${SECRETS_COUNT} secret(s) and ${VARS_COUNT} variable(s)"

# Try to find {key}_URI in Secrets
try_lookup_uri() {
  local k="${1}_URI"
  printf '%s' "${SECRETS_MAP[$k]-}"
}

# Try to find {key}_URL in Variables, {key}_USER in Variables, and {key}_PASSWORD in Secrets
try_lookup_url_user_password() {
  local lookup_key="$1"
  FOUND_URL="${VARS_MAP[${lookup_key}_URL]-}"
  FOUND_USER="${VARS_MAP[${lookup_key}_USER]-}"
  FOUND_PASSWORD="${SECRETS_MAP[${lookup_key}_PASSWORD]-}"
}

# Try to find {key}_DSN in Variables
try_lookup_dsn() {
  local k="${1}_DSN"
  printf '%s' "${VARS_MAP[$k]-}"
}

# Try to find {key}_PASSWORD in Secrets
try_lookup_password() {
  local k="${1}_PASSWORD"
  printf '%s' "${SECRETS_MAP[$k]-}"
}

# --- DSN inspection -------------------------------------------------------
# These INSPECT the DSN; they never rewrite it. What gets written to vault.json
# is the value exactly as it was read (ADR-0036 D7): normalisation belongs to
# TM, which is the only side that knows the connection type. Stripping the
# scheme here would turn mongodb://u:@h/db into u:@h/db and destroy the
# whole-string passthrough MongoDB relies on -- and this script has no way to
# tell MongoDB from JDBC, because the prefix must never be used to infer type.
#
# The checks still have to UNDERSTAND all three accepted JDBC forms, or they
# would report "no database" for the two prefixed ones.

# Strip the optional "jdbc:" and the optional "scheme://" -- inspection only.
dsn_strip_prefix() {
  local d="$1"
  d="${d#jdbc:}"
  if [[ "${d}" == *"://"* ]]; then d="${d#*://}"; fi
  printf '%s' "${d}"
}

# The authority: everything before the path or the query string.
dsn_authority() {
  local d
  d="$(dsn_strip_prefix "$1")"
  d="${d%%\?*}"
  d="${d%%/*}"
  printf '%s' "${d}"
}

# True when the DSN carries a NON-EMPTY password. Both "user:@host" and
# "user@host" are accepted spellings of an empty password position.
dsn_has_password() {
  local auth userinfo pw
  auth="$(dsn_authority "$1")"
  [[ "${auth}" == *"@"* ]] || return 1
  userinfo="${auth%@*}"
  [[ "${userinfo}" == *":"* ]] || return 1
  pw="${userinfo#*:}"
  [[ -n "${pw}" ]]
}

# True when the DSN carries a database name. Note mongodb://u:@h:27017/?a=b has
# a slash but no database -- the empty segment must not count as one.
dsn_has_database() {
  local d rest
  d="$(dsn_strip_prefix "$1")"
  d="${d%%\?*}"
  [[ "${d}" == *"/"* ]] || return 1
  rest="${d#*/}"
  [[ -n "${rest}" ]]
}

for conn_name in "${CONNECTION_NAMES[@]}"; do
  MATCH_TYPE=""
  FOUND_DSN=""
  FOUND_URI=""
  FOUND_URL=""
  FOUND_USER=""
  FOUND_PASSWORD=""
  FOUND_LOOKUP_KEY="${conn_name}"

  # Priority 1: {conn_name}_DSN in Variables (+ {conn_name}_PASSWORD in Secrets)
  FOUND_DSN=$(try_lookup_dsn "${conn_name}")
  if [[ -n "${FOUND_DSN}" ]]; then
    # A DSN carrying a real password is an ERROR, not a warning: Variables are
    # plaintext, readable by every collaborator, and end up in Actions logs.
    # The message must never echo the DSN -- GitHub masks Secrets but NOT
    # Variables, so echoing would write the password permanently into a log
    # anyone with read access can download, turning the check into the leak.
    if dsn_has_password "${FOUND_DSN}"; then
      echo "::error::Connection '${conn_name}': ${conn_name}_DSN must not contain a password."
      echo "::error::Variables are not masked by GitHub, so that password is already readable by everyone with repo access and is written to Actions logs. Rotate it now -- deleting the variable recovers nothing. Then set ${conn_name}_DSN with an empty password position and put the password in the ${conn_name}_PASSWORD secret."
      exit 1
    fi
    MATCH_TYPE="dsn"

    # Missing pieces warn and keep the target's existing value (ADR-0036 D10);
    # they are not errors and never write an empty value.
    if ! dsn_has_database "${FOUND_DSN}"; then
      echo "::warning::Connection '${conn_name}': ${conn_name}_DSN does not carry a database name; the target environment's existing database name will be kept."
    fi

    # The password half falls back, unlike the DSN half (ADR-0036 D4).
    FOUND_PASSWORD=$(try_lookup_password "${conn_name}")
    FOUND_PASSWORD_KEY="${conn_name}"
    if [[ -z "${FOUND_PASSWORD}" ]]; then
      PREFIX=$(get_prefix "${conn_name}")
      if [[ -n "${PREFIX}" && "${PREFIX}" != "${conn_name}" ]]; then
        FOUND_PASSWORD=$(try_lookup_password "${PREFIX}")
        [[ -n "${FOUND_PASSWORD}" ]] && FOUND_PASSWORD_KEY="${PREFIX}"
      fi
    fi
    if [[ -z "${FOUND_PASSWORD}" ]]; then
      FOUND_PASSWORD=$(try_lookup_password "DEFAULT")
      [[ -n "${FOUND_PASSWORD}" ]] && FOUND_PASSWORD_KEY="DEFAULT"
    fi
    if [[ -z "${FOUND_PASSWORD}" ]]; then
      # Naming the key verbatim is the whole point: a typo'd key name and a
      # genuinely password-less connection are indistinguishable in the data,
      # so this line is the only thing the person who typo'd will ever see.
      echo "::warning::Connection '${conn_name}': no password configured (looked for ${conn_name}_PASSWORD, then the truncated prefix, then DEFAULT_PASSWORD); treating it as a password-less connection."
    elif [[ "${FOUND_PASSWORD_KEY}" != "${conn_name}" ]]; then
      echo "Password for ${conn_name} resolved via ${FOUND_PASSWORD_KEY}_PASSWORD"
    fi
  fi

  # Priority 2: {conn_name}_URI in Secrets
  if [[ -z "${MATCH_TYPE}" ]]; then
    FOUND_URI=$(try_lookup_uri "${conn_name}")
    if [[ -n "${FOUND_URI}" ]]; then
      MATCH_TYPE="uri"
    fi
  fi

  # Priority 3: {conn_name}_URL in Variables + {conn_name}_USER in Variables + {conn_name}_PASSWORD in Secrets
  if [[ -z "${MATCH_TYPE}" ]]; then
    try_lookup_url_user_password "${conn_name}"
    if [[ -n "${FOUND_URL}" && -n "${FOUND_PASSWORD}" ]]; then
      MATCH_TYPE="url_user_password"
    fi
  fi

  # Priority 4: truncated prefix _URL + _USER + _PASSWORD
  if [[ -z "${MATCH_TYPE}" ]]; then
    PREFIX=$(get_prefix "${conn_name}")
    if [[ -n "${PREFIX}" && "${PREFIX}" != "${conn_name}" ]]; then
      echo "Retrying lookup with prefix: ${PREFIX} (original: ${conn_name})"
      try_lookup_url_user_password "${PREFIX}"
      if [[ -n "${FOUND_URL}" && -n "${FOUND_PASSWORD}" ]]; then
        MATCH_TYPE="url_user_password"
        FOUND_LOOKUP_KEY="${PREFIX}"
      fi
    fi
  fi

  # Priority 5: DEFAULT_URL + DEFAULT_USER + DEFAULT_PASSWORD
  if [[ -z "${MATCH_TYPE}" ]]; then
    echo "Retrying lookup with default (original: ${conn_name})"
    try_lookup_url_user_password "DEFAULT"
    if [[ -n "${FOUND_URL}" && -n "${FOUND_PASSWORD}" ]]; then
      MATCH_TYPE="url_user_password"
      FOUND_LOOKUP_KEY="DEFAULT"
    fi
  fi

  # Validate: at least one priority must have matched
  if [[ -z "${MATCH_TYPE}" ]]; then
    echo "::error::Missing config for connection '${conn_name}': could not find ${conn_name}_DSN (Variables), ${conn_name}_URI (Secrets), ${conn_name}_URL + ${conn_name}_PASSWORD, truncated prefix equivalents, or DEFAULT_URL + DEFAULT_PASSWORD"
    exit 1
  fi

  # Add to vault using the original connection name as key prefix
  if [[ "${MATCH_TYPE}" == "dsn" ]]; then
    # Written verbatim -- see the note on dsn_strip_prefix.
    VAULT_JSON=$(echo "${VAULT_JSON}" | jq \
      --arg dsn_key "${conn_name}_DSN" --arg dsn_val "${FOUND_DSN}" \
      '. + {($dsn_key): $dsn_val}')
    # No password found means the connection is password-less; write no key at
    # all rather than an empty one, so TM keeps the target's existing password
    # (ADR-0034 D5) instead of seeing a value and overwriting with blank.
    if [[ -n "${FOUND_PASSWORD}" ]]; then
      VAULT_JSON=$(echo "${VAULT_JSON}" | jq \
        --arg pass_key "${conn_name}_PASSWORD" --arg pass_val "${FOUND_PASSWORD}" \
        '. + {($pass_key): $pass_val}')
    fi
  elif [[ "${MATCH_TYPE}" == "uri" ]]; then
    VAULT_JSON=$(echo "${VAULT_JSON}" | jq \
      --arg uri_key "${conn_name}_URI" --arg uri_val "${FOUND_URI}" \
      '. + {($uri_key): $uri_val}')
  else
    VAULT_JSON=$(echo "${VAULT_JSON}" | jq \
      --arg url_key "${conn_name}_URL" --arg url_val "${FOUND_URL}" \
      --arg pass_key "${conn_name}_PASSWORD" --arg pass_val "${FOUND_PASSWORD}" \
      '. + {($url_key): $url_val, ($pass_key): $pass_val}')
    if [[ -n "${FOUND_USER}" ]]; then
      VAULT_JSON=$(echo "${VAULT_JSON}" | jq \
        --arg user_key "${conn_name}_USER" --arg user_val "${FOUND_USER}" \
        '. + {($user_key): $user_val}')
    fi
  fi

  if [[ "${FOUND_LOOKUP_KEY}" != "${conn_name}" ]]; then
    echo "Added vault for connection: ${conn_name} [${MATCH_TYPE}] (matched via prefix ${FOUND_LOOKUP_KEY})"
  else
    echo "Added vault for connection: ${conn_name} [${MATCH_TYPE}]"
  fi
done

# Write vault.json
VAULT_FILE="${EXPORT_DIR}/vault.json"
echo "${VAULT_JSON}" | jq '.' > "${VAULT_FILE}"

echo "vault.json written to ${VAULT_FILE}"
echo "Total connections: ${#CONNECTION_NAMES[@]}"
echo "=== vault.json Generated Successfully ==="
