# Setup do banco no Neon

Cria o schema que os microsserviços usam. Não precisa ter `psql` instalado — o script usa o driver `pg` do Node.

## Uma vez só

```bash
cd API-DSM-4-BANCO
npm install
```

O `.env` desta pasta já vem com a URL do Neon de development (ele não vai para o Git).

## Aplicar

```bash
npm run db:setup
```

Saída esperada:

```
Conectado em "neondb".

Aplicando schema... ok
Aplicando seed... ok

11 tabelas no schema public.
2 propriedade(s), 5 tipo(s) de sensor.

Use um destes property_id ao criar estações:
  1 - Fazenda Santa Clara
  2 - Sítio Boa Vista
```

Anote os `property_id` — você precisa deles para criar estações pela API.

**Idempotente.** Rodar de novo não duplica nem apaga nada. Se alguém do time já aplicou, é normal ver tudo passar de novo sem mudança.

### Variações

```bash
npm run db:schema    # só as tabelas
npm run db:seed      # só os dados de desenvolvimento

# Apontar para outro banco, sem mexer no .env:
node setup/apply.mjs "postgresql://usuario:senha@host.neon.tech/neondb?sslmode=require"
```

## Conferir

```bash
npm run db:schema
```

Ele reimprime o resumo. Para olhar as tabelas com mais detalhe, use o **SQL Editor** do painel do Neon:

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' ORDER BY 1;

SELECT * FROM processing_checkpoints;
```

Devem existir 11 tabelas: `roles`, `users`, `credentials`, `properties`, `stations`, `sensor_types`, `sensors`, `readings`, `alert_configs`, `triggered_alerts` e `processing_checkpoints`.

## Se quiser o psql mesmo assim

Não é necessário, mas o `psql` é útil para consultas soltas. No Windows, instale pelo [instalador do PostgreSQL](https://www.postgresql.org/download/windows/) marcando **Command Line Tools**, e adicione `C:\Program Files\PostgreSQL\17\bin` ao PATH.

```bash
psql "postgresql://usuario:senha@host.neon.tech/neondb?sslmode=require" -f setup/schema-neon.sql
```

Sem os sinais `<` e `>` em volta da URL — nos exemplos eles marcam "substitua aqui".

## Cuidados

**O banco `development` é compartilhado com o time.** Os scripts acima não destroem dados, mas o que você criar pelos endpoints é visto por todo mundo.

**Não aplique as migrations `010`, `011` e `012` no Neon.** Elas movem dados, renomeiam tabelas e removem uma FK — são a SCRUM-379 e exigem janela de manutenção combinada. Para testá-las, use um Postgres descartável com pg_partman: `benchmark/Dockerfile.postgres` + `benchmark/run.sh`.
