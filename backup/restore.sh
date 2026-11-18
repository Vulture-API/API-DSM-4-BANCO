#!/usr/bin/env bash
set -euo pipefail

BACKUP_FILE="${1:-}"
TARGET_DATABASE_URL="${TARGET_DATABASE_URL:-}"

if [ -z "${BACKUP_FILE}" ] || [ ! -f "${BACKUP_FILE}" ]; then
  echo "Uso: TARGET_DATABASE_URL=<url> $0 <caminho_do_arquivo.dump>" >&2
  exit 1
fi

if [ -z "${TARGET_DATABASE_URL}" ]; then
  echo "Erro: TARGET_DATABASE_URL nao definida." >&2
  exit 1
fi

CHECKSUM_FILE="${BACKUP_FILE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
  sha256sum -c "${CHECKSUM_FILE}"
fi

pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  --exit-on-error \
  --dbname="${TARGET_DATABASE_URL}" \
  "${BACKUP_FILE}"

psql "${TARGET_DATABASE_URL}" -v ON_ERROR_STOP=1 -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name;"

echo "Restauracao concluida e validada: ${BACKUP_FILE}"
