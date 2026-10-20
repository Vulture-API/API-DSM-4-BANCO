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

## SCRUM-448 — limites e precisão da telemetria

O setup/schema incorpora `sensors.min_value` e `sensors.max_value` como NUMERIC
opcionais, sem limites presumidos. A constraint `sensors_limits_valid` impede
limites não finitos e mínimo maior que máximo. Igualdade é válida. A migration
`016_sensor_limits_and_reading_precision.sql` amplia `readings.value` para NUMERIC
sem escala fixa e adapta limites numéricos adicionados manualmente. O setup aplica
schema → permissões 015 → telemetria 016 → seed. `npm run db:schema` também aplica
015/016; `db:seed` continua executando somente o seed.

Para banco existente, a 016 exige **janela de manutenção**, writers e refreshes
parados, backup e permissões de proprietário dos objetos afetados. Ela toma locks
com `lock_timeout=10s` e executa em uma transação; qualquer erro reverte a operação.
Testar antes em cópia descartável. Não executar as migrations 010–012 apenas para
ampliar precisão; elas pertencem ao trabalho de particionamento e movimentam dados.

A 016 pode ser reaplicada. Preserva leituras, FKs, índices e nulabilidade. No banco
particionado, altera o pai e seus descendentes; também altera o template registrado
no pg_partman para impedir que partições futuras voltem a duas casas decimais.
A criação da tabela na 010 foi alinhada ao tipo NUMERIC para novas instalações.

Quando presente, `mv_latest_readings` é recriada dentro da transação com a definição
original, estado populado/não populado, índices, proprietário, permissões de tabela
e coluna, comentários, opções e tablespace. Não usa CASCADE. Dependências não
previstas ou tipos incompatíveis abortam a migration; revisar o erro antes de
qualquer reaplicação. Depois, conferir dados, tipos das partições/template e
`REFRESH MATERIALIZED VIEW CONCURRENTLY mv_latest_readings`.

NUMERIC sem escala fixa preserva os decimais recebidos até os limites PostgreSQL
(131072 dígitos integrais e 16383 fracionários). Valores históricos já arredondados
não são recuperáveis. O tratamento independente da SCRUM-448 usa Decimal e valida
essa representabilidade. As APIs existentes continuam retornando números via
float8/JavaScript, com limitações de precisão e de amplitude; seu contrato não muda.

Testes descartáveis:

```bash
TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/test node --test
```

O CI usa PostgreSQL 16 com pg_partman, integrações obrigatórias sem skips, setup
repetido, permissões, migrations de particionamento, 016 repetida e benchmark
reduzido. Nada aplica alterações em Neon ou outro banco externo automaticamente.
