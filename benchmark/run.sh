#!/usr/bin/env bash
# SCRUM-379 — Mede o efeito das otimizações: popula, mede, migra, mede de novo.
#
#   ./benchmark/run.sh "postgresql://user:senha@localhost:5432/banco"
#
# Gera benchmark/resultado-antes.txt e benchmark/resultado-depois.txt.
#
# Use um banco DESCARTÁVEL: o script insere massa e aplica migrations que
# movem dados.
set -euo pipefail

DATABASE_URL="${1:-${DATABASE_URL:-}}"
ROWS="${ROWS:-1000000}"
MONTHS="${MONTHS:-12}"
SENSORS="${SENSORS:-50}"

if [ -z "$DATABASE_URL" ]; then
  echo "Uso: $0 <DATABASE_URL>" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A migration 010 delega o ciclo de vida das partições ao pg_partman. Sem a
# extensão, o benchmark quebraria no meio, depois de já ter inserido a massa.
# Melhor falhar aqui, antes de gastar o tempo do seed.
if ! psql "$DATABASE_URL" -tAc \
  "SELECT 1 FROM pg_available_extensions WHERE name = 'pg_partman'" | grep -q 1; then
  cat >&2 <<'ERRO'
pg_partman não está disponível neste banco.

  Local:  docker build -t bench-postgres -f benchmark/Dockerfile.postgres benchmark/
          docker run -d --name bench-postgres -e POSTGRES_PASSWORD=postgres \
            -p 5432:5432 bench-postgres

  Neon:   já vem disponível; a 010 cria a extensão sozinha.
ERRO
  exit 1
fi

echo "==> Populando $ROWS leituras ($MONTHS meses, $SENSORS sensores)..."
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -v rows="$ROWS" -v months="$MONTHS" -v sensors="$SENSORS" \
  -f "$DIR/seed_readings.sql"

echo "==> Medindo ANTES..."
# Sem ON_ERROR_STOP: a consulta 7 usa a materialized view, que ainda não
# existe nesta etapa. O erro no relatório é esperado.
psql "$DATABASE_URL" -f "$DIR/benchmark.sql" > "$DIR/resultado-antes.txt" 2>&1

echo "==> Aplicando migrations..."
for migration in 010_readings_partitioning 011_readings_indexes_and_tuning 012_partition_maintenance; do
  echo "    - $migration"
  psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -f "$DIR/../migrations/${migration}.sql"
done

psql "$DATABASE_URL" -q -c "ANALYZE readings;"

echo "==> Medindo DEPOIS..."
psql "$DATABASE_URL" -f "$DIR/benchmark.sql" > "$DIR/resultado-depois.txt" 2>&1

echo
echo "Pronto. Compare os tempos de execução:"
echo "  $DIR/resultado-antes.txt"
echo "  $DIR/resultado-depois.txt"
echo
grep -E "=====|Execution Time" "$DIR/resultado-antes.txt"  | sed 's/^/  ANTES  /' || true
echo
grep -E "=====|Execution Time" "$DIR/resultado-depois.txt" | sed 's/^/  DEPOIS /' || true
