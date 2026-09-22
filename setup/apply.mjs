// Aplica os scripts SQL no banco, sem depender do psql instalado.
//
//   npm run db:setup          -> schema + seed
//   npm run db:schema         -> só o schema
//   npm run db:seed           -> só o seed
//
// A URL vem de DATABASE_URL (.env deste diretório) ou do primeiro argumento.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import "dotenv/config";
import pg from "pg";

const here = dirname(fileURLToPath(import.meta.url));

// Tolera a URL colada com < > ou aspas em volta, que é como os exemplos
// da documentação a escrevem.
const limpar = (valor) => (valor ?? "").trim().replace(/^[<"']+|[>"']+$/g, "");

const args = process.argv.slice(2).map(limpar);
const urlFromArg = args.find((a) => a.startsWith("postgres"));
const only = args.find((a) => a === "schema" || a === "seed");

const url = urlFromArg ?? limpar(process.env.DATABASE_URL);

if (!url) {
  console.error(
    "Faltou a DATABASE_URL.\n" +
      "  Crie um .env nesta pasta com DATABASE_URL=..., ou passe a URL como argumento:\n" +
      "  node setup/apply.mjs postgresql://usuario:senha@host.neon.tech/neondb?sslmode=require",
  );
  process.exit(1);
}

const files = [
  { nome: "schema", caminho: join(here, "schema-neon.sql") },
  { nome: "seed", caminho: join(here, "seed-dev.sql") },
].filter((f) => !only || f.nome === only);

const client = new pg.Client({
  connectionString: url,
  connectionTimeoutMillis: 20000,
});

try {
  await client.connect();
  const { rows } = await client.query(
    "SELECT current_database() AS db, current_setting('server_version') AS versao",
  );
  console.log(`Conectado em "${rows[0].db}" (PostgreSQL ${rows[0].versao}).\n`);

  for (const { nome, caminho } of files) {
    process.stdout.write(`Aplicando ${nome}... `);
    await client.query(readFileSync(caminho, "utf8"));
    console.log("ok");
  }

  const resumo = await client.query(`
    SELECT
      (SELECT count(*) FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS tabelas,
      (SELECT count(*) FROM properties)   AS propriedades,
      (SELECT count(*) FROM sensor_types) AS tipos_de_sensor
  `);

  const r = resumo.rows[0];
  console.log(
    `\n${r.tabelas} tabelas no schema public.` +
      `\n${r.propriedades} propriedade(s), ${r.tipos_de_sensor} tipo(s) de sensor.`,
  );

  const props = await client.query("SELECT id, name FROM properties ORDER BY id");
  if (props.rowCount > 0) {
    console.log("\nUse um destes property_id ao criar estações:");
    for (const p of props.rows) console.log(`  ${p.id} - ${p.name}`);
  }
} catch (error) {
  // `throw` em JS aceita qualquer valor (string, null...): não assumir .message.
  const mensagem = error instanceof Error ? error.message : String(error);
  console.error("\nFALHOU:", mensagem);
  if (mensagem.includes("getaddrinfo") || mensagem.includes("ENOTFOUND")) {
    console.error("Verifique a URL e se você tem acesso à internet.");
  }
  process.exit(1);
} finally {
  await client.end().catch(() => {});
}
