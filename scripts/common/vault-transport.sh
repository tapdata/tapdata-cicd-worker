#!/usr/bin/env bash
# Transport vault.json between Jobs via a local run-scoped file (GHES artifact fallback).
# Usage: vault-transport.sh push | pull
#
# Required env:
#   DEPLOY_DIR  - run-scoped temp dir (/tmp/tapdata-deploy-<run_id>); shared across Jobs on a single runner
#   VAULT_FILE  - path to vault.json inside the export dir
# pull additionally requires:
#   PREP_RUNNER - runner.name recorded by the preparation Job
#   RUNNER_NAME - injected by GitHub on the current runner
#
# The transport file uses a dedicated name (vault-transport.enc) so that
# compress-files.sh (which writes $DEPLOY_DIR/vault.json) never overwrites it.
set -euo pipefail

ACTION="${1:-}"
: "${DEPLOY_DIR:?DEPLOY_DIR not set}"
TRANSPORT_FILE="${DEPLOY_DIR}/vault-transport.enc"

case "${ACTION}" in
  push)
    : "${VAULT_FILE:?VAULT_FILE not set}"
    if [[ ! -f "${VAULT_FILE}" ]]; then
      echo "::error::vault file not found for push: ${VAULT_FILE}"
      exit 1
    fi
    mkdir -p "${DEPLOY_DIR}"
    cp "${VAULT_FILE}" "${TRANSPORT_FILE}"
    echo "Local vault transport pushed: ${TRANSPORT_FILE}"
    ;;
  pull)
    : "${VAULT_FILE:?VAULT_FILE not set}"
    : "${PREP_RUNNER:?PREP_RUNNER not set}"
    CURRENT_RUNNER="${RUNNER_NAME:-}"
    if [[ "${CURRENT_RUNNER}" != "${PREP_RUNNER}" ]]; then
      echo "::error::Job ran on a different runner (prep=${PREP_RUNNER}, current=${CURRENT_RUNNER}). Local-file vault transport requires all Jobs on a single runner. Enable artifacts or pin the pipeline to one runner."
      exit 1
    fi
    if [[ ! -f "${TRANSPORT_FILE}" ]]; then
      echo "::error::Local vault transport file not found: ${TRANSPORT_FILE}. The Job likely ran on a different runner, or preparation failed to produce the vault."
      exit 1
    fi
    mkdir -p "$(dirname "${VAULT_FILE}")"
    cp "${TRANSPORT_FILE}" "${VAULT_FILE}"
    echo "Local vault transport pulled: ${VAULT_FILE}"
    ;;
  *)
    echo "::error::usage: vault-transport.sh push|pull"
    exit 1
    ;;
esac
