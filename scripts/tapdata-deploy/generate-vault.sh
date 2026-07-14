#!/usr/bin/env bash
# Generate vault.json with connection secrets from GitHub Secrets and Variables
# Required env vars: PROJECT, ALL_SECRETS, ALL_VARS
# ALL_SECRETS comes from ${{ toJSON(secrets) }}
# ALL_VARS comes from ${{ toJSON(vars) }}
# Lookup priority (stop at first match):
#   1. {CONNECTION_NAME}_URI in Secrets
#   2. {CONNECTION_NAME}_URL (Variables) + {CONNECTION_NAME}_USER (Variables) + {CONNECTION_NAME}_PASSWORD (Secrets)
#   3. Truncate name to prefix before the 2nd underscore (e.g. A_B_C_D -> A_B),
#      then {PREFIX}_URL (Variables) + {PREFIX}_USER (Variables) + {PREFIX}_PASSWORD (Secrets)
#   4. DEFAULT_URL (Variables) + DEFAULT_USER (Variables) + DEFAULT_PASSWORD (Secrets)
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
#   1. {NAME}_URI in Secrets
#   2. {NAME}_URL (Variables) + {NAME}_USER (Variables) + {NAME}_PASSWORD (Secrets)
#   3. Truncate to prefix (A_B_C_D -> A_B), then {PREFIX}_URL + {PREFIX}_USER + {PREFIX}_PASSWORD
#   4. DEFAULT_URL (Variables) + DEFAULT_USER (Variables) + DEFAULT_PASSWORD (Secrets)
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

# Try to find {key}_URI in Secrets
try_lookup_uri() {
  local lookup_key="$1"
  echo "${ALL_SECRETS}" | jq -r --arg k "${lookup_key}_URI" '.[$k] // empty'
}

# Try to find {key}_URL in Variables, {key}_USER in Variables, and {key}_PASSWORD in Secrets
try_lookup_url_user_password() {
  local lookup_key="$1"
  FOUND_URL=$(echo "${ALL_VARS}" | jq -r --arg k "${lookup_key}_URL" '.[$k] // empty')
  FOUND_USER=$(echo "${ALL_VARS}" | jq -r --arg k "${lookup_key}_USER" '.[$k] // empty')
  FOUND_PASSWORD=$(echo "${ALL_SECRETS}" | jq -r --arg k "${lookup_key}_PASSWORD" '.[$k] // empty')
}

for conn_name in "${CONNECTION_NAMES[@]}"; do
  MATCH_TYPE=""
  FOUND_URI=""
  FOUND_URL=""
  FOUND_USER=""
  FOUND_PASSWORD=""
  FOUND_LOOKUP_KEY="${conn_name}"

  # Priority 1: {conn_name}_URI in Secrets
  FOUND_URI=$(try_lookup_uri "${conn_name}")
  if [[ -n "${FOUND_URI}" ]]; then
    MATCH_TYPE="uri"
  fi

  # Priority 2: {conn_name}_URL in Variables + {conn_name}_USER in Variables + {conn_name}_PASSWORD in Secrets
  if [[ -z "${MATCH_TYPE}" ]]; then
    try_lookup_url_user_password "${conn_name}"
    if [[ -n "${FOUND_URL}" && -n "${FOUND_PASSWORD}" ]]; then
      MATCH_TYPE="url_user_password"
    fi
  fi

  # Priority 3: truncated prefix _URL + _USER + _PASSWORD
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

  # Priority 4: DEFAULT_URL + DEFAULT_USER + DEFAULT_PASSWORD
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
    echo "::error::Missing config for connection '${conn_name}': could not find ${conn_name}_URI (Secrets), ${conn_name}_URL + ${conn_name}_PASSWORD, truncated prefix equivalents, or DEFAULT_URL + DEFAULT_PASSWORD"
    exit 1
  fi

  # Add to vault using the original connection name as key prefix
  if [[ "${MATCH_TYPE}" == "uri" ]]; then
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
