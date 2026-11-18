#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/vulture-postgres}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
DATABASE_URL="${DATABASE_URL:-}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="${BACKUP_DIR}/vulture_${TIMESTAMP}.dump"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"

if [ -z "${DATABASE_URL}" ]; then
  echo "Erro: DATABASE_URL nao definida." >&2
  exit 1
fi

install -d -m 700 "${BACKUP_DIR}"
umask 077

pg_dump \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-privileges \
  --file="${BACKUP_FILE}" \
  "${DATABASE_URL}"

chmod 600 "${BACKUP_FILE}"
sha256sum "${BACKUP_FILE}" > "${CHECKSUM_FILE}"
chmod 600 "${CHECKSUM_FILE}"

find "${BACKUP_DIR}" -type f \( -name "vulture_*.dump" -o -name "vulture_*.dump.sha256" \) -mtime "+${BACKUP_RETENTION_DAYS}" -delete

echo "Backup concluido: ${BACKUP_FILE}"
