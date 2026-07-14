#!/usr/bin/env bash
set -euo pipefail

# Encrypt or decrypt vault.json using AES-256-CBC
# Required env vars: VAULT_FILE, CRYPTO_ACTION (encrypt|decrypt)
# Optional env var: VAULT_ENCRYPTION_KEY (skip if empty)

if [[ -z "${VAULT_ENCRYPTION_KEY:-}" ]]; then
  echo "VAULT_ENCRYPTION_KEY not set, skipping ${CRYPTO_ACTION}"
  exit 0
fi

if [[ ! -f "${VAULT_FILE}" ]]; then
  echo "Warning: ${VAULT_FILE} not found, skipping ${CRYPTO_ACTION}"
  exit 0
fi

case "${CRYPTO_ACTION}" in
  encrypt)
    openssl enc -aes-256-cbc -pbkdf2 -salt \
      -in "${VAULT_FILE}" \
      -out "${VAULT_FILE}.enc" \
      -pass env:VAULT_ENCRYPTION_KEY
    rm -f "${VAULT_FILE}"
    mv "${VAULT_FILE}.enc" "${VAULT_FILE}"
    echo "vault.json encrypted successfully"
    ;;
  decrypt)
    cp "${VAULT_FILE}" "${VAULT_FILE}.enc"
    openssl enc -aes-256-cbc -pbkdf2 -d \
      -in "${VAULT_FILE}.enc" \
      -out "${VAULT_FILE}" \
      -pass env:VAULT_ENCRYPTION_KEY
    rm -f "${VAULT_FILE}.enc"
    echo "vault.json decrypted successfully"
    ;;
  *)
    echo "Error: CRYPTO_ACTION must be 'encrypt' or 'decrypt', got '${CRYPTO_ACTION}'"
    exit 1
    ;;
esac
