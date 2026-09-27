# Manutenção agendada do banco (SCRUM-379)

`maintenance.ts` roda como **Neon Scheduled Function Trigger**. É o que mantém o
particionamento de `readings` funcionando sozinho.

## Por que aqui e não em `pg_cron`

No Neon, os jobs do `pg_cron` só rodam **enquanto a compute está ativa**. Com
scale-to-zero ligado — que é o padrão e o que faz sentido para um projeto de
faculdade — o job simplesmente não acontece, e sem erro nenhum. As Scheduled
Function Triggers disparam mesmo com a compute dormindo.

## Rotas

| Rota | Cron (UTC) | O que faz |
| --- | --- | --- |
| `/maintenance` | `0 6 * * *` | `partman.run_maintenance_proc()` + checagem da partição DEFAULT |
| `/refresh` | `* * * * *` | `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_latest_readings` |

`0 6 * * *` em UTC é 03:00 em São Paulo. O cron do Neon é **sempre UTC** e só
aceita os cinco campos numéricos — nada de `@daily` ou `MON`.

## Deploy

```bash
neon functions deploy neon/maintenance.ts --name readings-maintenance

neon triggers create \
  --function readings-maintenance \
  --name readings-partman \
  --schedule "0 6 * * *" \
  --path /maintenance

neon triggers create \
  --function readings-maintenance \
  --name readings-mv-refresh \
  --schedule "* * * * *" \
  --path /refresh
```

`DATABASE_URL` é injetada pelo Neon; não precisa ser configurada à mão.

## Como saber que está funcionando

A função responde **500** quando algo falha, e é isso que faz a execução
aparecer como erro no console do Neon. O caso que mais importa é a partição
`DEFAULT` deixar de estar vazia: `assert_readings_default_empty()` levanta
exceção, o handler devolve 500, e a falha vira visível em vez de silenciosa.

Mas há um caso que um 500 não cobre: **o agendamento ser desativado ou nunca
publicado.** Aí nada roda e nada reclama. Por isso a manutenção grava um
heartbeat a cada execução bem-sucedida:

```sql
SELECT * FROM vw_maintenance_status;   -- atrasado = true se passou de 7 dias
```

Vale expor essa view no `/health` do serviço de consulta.

Checagem manual:

```sql
SELECT count(*) FROM readings_default;     -- tem que ser 0
SELECT * FROM partman.part_config WHERE parent_table = 'public.readings';
```

## Se o time sair do Neon

O mesmo roteiro vira um workflow agendado no GitHub Actions:

```yaml
on:
  schedule:
    - cron: "0 6 * * *"
jobs:
  manutencao:
    runs-on: ubuntu-latest
    steps:
      - run: |
          psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
            -c "CALL partman.run_maintenance_proc();" \
            -c "SELECT assert_readings_default_empty();" \
            -c "SELECT record_maintenance_heartbeat('partman');"
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

O `ON_ERROR_STOP=1` é o que faz o workflow ficar vermelho quando a checagem
falha. Sem ele, volta a ser silencioso.
