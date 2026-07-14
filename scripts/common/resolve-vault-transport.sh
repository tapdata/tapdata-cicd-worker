#!/usr/bin/env bash
# Decide the vault transport mode once in the preparation Job, stage the local
# transport file when needed, and emit Job outputs.
# Runs right after the artifact-upload attempt (v4).
#
# Transport modes (vault_transport output):
#   artifact-v4 - upload-artifact@v4 succeeded; downstream downloads via @v4
#   local       - artifact upload unavailable (or forced); local-file transport
#
# Required env:
#   FORCED_TRANSPORT  - value of vars.VAULT_TRANSPORT ('', 'auto', 'local', or 'artifact')
#   UPLOAD_V4_OUTCOME - steps.upload_vault_v4.outcome ('success'|'failure'|'skipped'|'')
#   DEPLOY_DIR        - run-scoped temp dir
#   VAULT_FILE        - path to the (already encrypted) vault.json
#   RUNNER_NAME       - injected by GitHub; recorded as prep_runner output
#   GITHUB_OUTPUT     - injected by GitHub; where Job outputs are written
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCED="${FORCED_TRANSPORT:-}"
V4="${UPLOAD_V4_OUTCOME:-}"

case "${FORCED}" in
  local)
    MODE="local" ;;
  ""|auto|artifact)
    if [[ "${V4}" == "success" ]]; then
      MODE="artifact-v4"
    elif [[ "${FORCED}" == "artifact" ]]; then
      echo "::error::VAULT_TRANSPORT=artifact but upload-artifact@v4 failed; refusing to fall back to local file. Check artifact support on this runner/GHES, or use VAULT_TRANSPORT=auto (allows local fallback) or local."
      exit 1
    else
      MODE="local"
    fi ;;
  *)
    echo "::error::Invalid VAULT_TRANSPORT='${FORCED}' (expected one of: auto, local, artifact)"
    exit 1 ;;
esac

if [[ "${MODE}" == "local" ]]; then
  echo "::warning::artifact transport unavailable or disabled; using local-file vault transport"
  bash "${SCRIPT_DIR}/vault-transport.sh" push
fi

{
  echo "vault_transport=${MODE}"
  echo "prep_runner=${RUNNER_NAME:-}"
} >> "${GITHUB_OUTPUT}"

echo "Resolved vault_transport=${MODE}, prep_runner=${RUNNER_NAME:-}"
