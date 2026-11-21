# Estratégia de Backup e Restauração do Banco de Dados (SCRUM-544 / RNF10)

## 1. Objetivo e Rastreabilidade

Este documento define a estratégia de backup, retenção, armazenamento seguro e procedimento de restauração do banco de dados PostgreSQL do sistema AgriTech, atendendo à tarefa **SCRUM-544** e ao requisito não funcional **RNF10** (disponibilidade, integridade e recuperação de dados).

## 2. Escopo dos Dados Incluídos no Backup

O backup lógico contempla todas as tabelas, índices, restrições, sequências e dados do schema `public` do banco PostgreSQL (Neon DB):
- Controle de acesso: `roles`, `users`, `credentials`, `role_permissions` (quando aplicável)
- Estrutura de monitoramento: `properties`, `stations`, `sensor_types`, `sensors`
- Séries temporais e telemetria: `readings`, `processing_checkpoints`
- Alertas e ocorrências: `alert_configs`, `triggered_alerts`, `occurrences`

O backup utiliza `pg_dump` em formato customizado (`--format=custom --compress=9 --no-owner --no-privileges`), permitindo restauração seletiva ou integral via `pg_restore`.

## 3. Periodicidade e Política de Retenção

| Camada | Mecanismo | Periodicidade | Retenção |
| --- | --- | --- | --- |
| Primária (Nativa) | Point-in-Time Recovery (PITR) / Snapshots Neon DB | Contínua (WAL) | Conforme plano contratado no Neon |
| Secundária (Lógica) | Script `backup/backup.sh` via cron na EC2 | Diária às 03:00 UTC | 14 dias (`BACKUP_RETENTION_DAYS=14`) |
| Pré-migração | Execução manual de `backup/backup.sh` | Antes de alterações estruturais em produção | 14 dias |

Exemplo de agendamento no `cron` da instância EC2 (executado como usuário restrito ou `root` carregando `DATABASE_URL` do `.env`):

```cron
0 3 * * * set -a && . /opt/vulture/API-DSM-4-INFRA/.env && set +a && /opt/vulture/API-DSM-4-BANCO/backup/backup.sh >> /var/log/vulture-backup.log 2>&1
```

## 4. Armazenamento e Segurança

- **Local de armazenamento**: diretório dedicado `/var/backups/vulture-postgres` no volume EBS criptografado (`gp3`) da instância EC2, com opção de replicação para bucket S3 privado com criptografia SSE-S3 e bloqueio de acesso público.
- **Controle de acesso**: o diretório é criado com permissão `700` (`drwx------`) e os arquivos `.dump` e `.sha256` são gravados com `umask 077` e `chmod 600` (`-rw-------`).
- **Proteção de credenciais**: `DATABASE_URL` é fornecida exclusivamente via variável de ambiente em tempo de execução, nunca gravada nos arquivos de backup nem exibida nos logs.
- **Integridade**: todo arquivo `.dump` gera um hash SHA-256 (`.dump.sha256`) validado automaticamente antes de qualquer restauração.

## 5. Procedimento de Backup

```bash
DATABASE_URL="postgresql://<usuario>:<senha>@<host>/<banco>?sslmode=require" \
BACKUP_DIR="/var/backups/vulture-postgres" \
BACKUP_RETENTION_DAYS=14 \
./backup/backup.sh
```

## 6. Procedimento de Restauração

1. Provisionar ou selecionar o banco de destino (`TARGET_DATABASE_URL`), preferencialmente um banco limpo para validação antes da troca de produção.
2. Executar o script de restauração apontando para o arquivo `.dump` desejado:

```bash
TARGET_DATABASE_URL="postgresql://<usuario>:<senha>@<host>/<banco_destino>?sslmode=require" \
./backup/restore.sh /var/backups/vulture-postgres/vulture_YYYYMMDDTHHMMSSZ.dump
```

3. O script valida o checksum SHA-256, executa `pg_restore --clean --if-exists --no-owner --no-privileges --exit-on-error` e lista as tabelas restauradas no schema `public`.
4. Após validar a contagem de registros e integridade da aplicação contra o banco restaurado, atualizar `DATABASE_URL` no `.env` da EC2 e reiniciar os serviços.

## 7. Evidência do Teste de Restauração

Teste executado em **18/11/2026** utilizando container PostgreSQL 16 (`postgres:16-alpine`), populando `source_db` com `setup/schema-neon.sql` e `setup/seed-demo.sql`, gerando backup com `backup/backup.sh` e restaurando em `restore_db` com `backup/restore.sh`:

- **Arquivo gerado**: `vulture_20261118T231735Z.dump` (687.157 bytes, permissão `600`, diretório `700`)
- **Validação de integridade**: `sha256sum -c` retornou `OK`
- **Restauração**: 11 tabelas restauradas sem erros (`--exit-on-error`)
- **Comparação de registros (`source_db` vs `restore_db`)**:

| Tabela | Origem (`source_db`) | Restaurado (`restore_db`) | Status |
| --- | ---: | ---: | --- |
| `roles` | 3 | 3 | Validado |
| `users` | 10 | 10 | Validado |
| `properties` | 6 | 6 | Validado |
| `stations` | 15 | 15 | Validado |
| `sensor_types` | 7 | 7 | Validado |
| `sensors` | 93 | 93 | Validado |
| `readings` | 87.996 | 87.996 | Validado |
