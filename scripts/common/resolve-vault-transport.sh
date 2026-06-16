#!/usr/bin/env bash
# Decide the vault transport mode (artifact|local) once in the preparation Job,
# stage the local transport file when needed, and emit Job outputs.
# Runs right after the artifact-upload attempt.
#
# Required env:
#   FORCED_TRANSPORT - value of vars.VAULT_TRANSPORT ('', 'auto', 'local', or 'artifact')
#   UPLOAD_OUTCOME   - steps.upload_vault.outcome ('success' | 'failure' | 'skipped' | '')
#   DEPLOY_DIR       - run-scoped temp dir
#   VAULT_FILE       - path to the (already encrypted) vault.json
#   RUNNER_NAME      - injected by GitHub; recorded as prep_runner output
#   GITHUB_OUTPUT    - injected by GitHub; where Job outputs are written
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT not set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCED="${FORCED_TRANSPORT:-}"
case "${FORCED}" in
  artifact)
    MODE="artifact" ;;
  local)
    MODE="local" ;;
  ""|auto)
    if [[ "${UPLOAD_OUTCOME:-}" == "success" ]]; then
      MODE="artifact"
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
