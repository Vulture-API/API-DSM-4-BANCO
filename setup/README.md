# Setup do banco no Neon

Cria o schema utilizado pelo backend, incluindo o catálogo e as associações de permissões da SCRUM-432. Não precisa ter `psql` instalado — o script usa o driver `pg` do Node.

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
Aplicando permissions... ok
Aplicando seed... ok

13 tabelas no schema public.
2 propriedade(s), 5 tipo(s) de sensor.

Use um destes property_id ao criar estações:
  1 - Fazenda Santa Clara
  2 - Sítio Boa Vista
```

Anote os `property_id` — você precisa deles para criar estações pela API.

**Idempotente.** Rodar de novo não duplica nem apaga nada. Se alguém do time já aplicou, é normal ver tudo passar de novo sem mudança.

### Variações

```bash
npm run db:schema    # tabelas e migration 015 de permissões
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

Devem existir 13 tabelas: `roles`, `users`, `credentials`, `properties`, `stations`, `sensor_types`, `sensors`, `readings`, `alert_configs`, `triggered_alerts` `processing_checkpoints`, `permissions` e `role_permissions`.

## Se quiser o psql mesmo assim

Não é necessário, mas o `psql` é útil para consultas soltas. No Windows, instale pelo [instalador do PostgreSQL](https://www.postgresql.org/download/windows/) marcando **Command Line Tools**, e adicione `C:\Program Files\PostgreSQL\17\bin` ao PATH.

```bash
psql "postgresql://usuario:senha@host.neon.tech/neondb?sslmode=require" -f setup/schema-neon.sql
```

Sem os sinais `<` e `>` em volta da URL — nos exemplos eles marcam "substitua aqui".

## Cuidados

**O banco `development` é compartilhado com o time.** Os scripts acima não destroem dados, mas o que você criar pelos endpoints é visto por todo mundo.

**Não aplique as migrations `010`, `011` e `012` no Neon.** Elas movem dados, renomeiam tabelas e removem uma FK — são a SCRUM-379 e exigem janela de manutenção combinada. Para testá-las, use um Postgres descartável com pg_partman: `benchmark/Dockerfile.postgres` + `benchmark/run.sh`.

## SCRUM-432 — Permissões por perfil

O setup executa `migrations/015_role_permissions.sql` depois do schema e antes do seed. O script é aditivo: cria `permissions` e `role_permissions`, com 31 códigos, chave composta e FKs. Na primeira instalação concede o catálogo ao Administrador existente, localizado pelo nome. O seed concede permissões somente quando cria um novo Administrador. Reaplicar migration/seed não restaura concessões revogadas.

Ao executar SQL manualmente, aplique schema → migration 015 → seed-dev. A migration não modifica credenciais nem usuários existentes. Não há concessões automáticas para Gerente Agrícola, Cliente ou perfis criados pelo CRUD.

Validação isolada:

```bash
TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:5433/agritech_test npm test
```

O teste cria um schema com UUID e o remove no final. Use conexão direta com permissão de criação de schemas. Em 2026-10-10, a validação passou com PostgreSQL de desenvolvimento e a migration foi aplicada: 31 concessões para Administrador, zero para os demais perfis existentes. A proteção das APIs anteriores depende de `ACCESS_CONTROL_ENABLED=true` no backend; as novas APIs de permissões sempre exigem JWT e autorização. A configuração de autenticação e o contrato HTTP estão em `docs/permissoes.md` do BACKEND.
