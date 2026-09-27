// SCRUM-379 — Manutenção agendada de `readings`.
//
// Roda como Neon Scheduled Function Trigger. Duas rotas, dois agendamentos:
//
//   /maintenance  diário  — cria partições à frente, expurga as vencidas
//   /refresh      minuto  — atualiza mv_latest_readings para o dashboard
//
// Agendamento e deploy em neon/README.md.

import { Pool } from "@neondatabase/serverless";

// Pool (WebSocket), e não o driver HTTP: `run_maintenance_proc` é uma
// PROCEDURE que dá COMMIT internamente, e `REFRESH ... CONCURRENTLY` não roda
// dentro de transação. Os dois precisam de sessão com autocommit.
const pool = new Pool({ connectionString: process.env.DATABASE_URL });

type Resultado = {
  ok: boolean;
  rota: string;
  invocacao: string | null;
  duracaoMs: number;
  detalhe?: unknown;
  erro?: string;
};

async function manutencao(): Promise<unknown> {
  const client = await pool.connect();
  try {
    // Idempotente e barato: cria o que falta à frente (premake = 4) e dá DROP
    // nas partições além da retenção de 24 meses.
    await client.query("CALL partman.run_maintenance_proc()");

    // Transforma em erro a falha que o Postgres não reporta: leitura caindo na
    // partição DEFAULT porque a manutenção parou de rodar.
    await client.query("SELECT assert_readings_default_empty()");

    // Heartbeat: registra que a manutenção rodou. É o que permite detectar o
    // caso em que o próprio agendamento foi desativado e, por isso, nada
    // reclamaria. `vw_maintenance_status` expõe o atraso.
    await client.query("SELECT record_maintenance_heartbeat($1)", ["partman"]);

    const { rows } = await client.query(
      `SELECT count(*)::int AS particoes,
              pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS tamanho
         FROM pg_class c
         JOIN pg_inherits i ON i.inhrelid = c.oid
         JOIN pg_class p ON p.oid = i.inhparent
        WHERE p.relname = 'readings'`,
    );
    return rows[0];
  } finally {
    client.release();
  }
}

async function refresh(): Promise<unknown> {
  const client = await pool.connect();
  try {
    // CONCURRENTLY para não bloquear o dashboard durante a atualização.
    // Exige o índice único mv_latest_readings_sensor_idx, criado na 011.
    await client.query("REFRESH MATERIALIZED VIEW CONCURRENTLY mv_latest_readings");
    const { rows } = await client.query("SELECT count(*)::int AS sensores FROM mv_latest_readings");
    return rows[0];
  } finally {
    client.release();
  }
}

export default async function handler(request: Request): Promise<Response> {
  const inicio = Date.now();
  const rota = new URL(request.url).pathname;

  // O Neon reenvia uma invocação que não respondeu. As duas operações são
  // idempotentes, então o id serve para correlacionar log, não para bloquear.
  const invocacao = request.headers.get("X-Neon-Trigger-Invocation-Id");

  const responder = (corpo: Resultado, status: number) =>
    new Response(JSON.stringify(corpo), {
      status,
      headers: { "content-type": "application/json" },
    });

  try {
    const detalhe = rota.startsWith("/refresh") ? await refresh() : await manutencao();
    const resultado: Resultado = {
      ok: true,
      rota,
      invocacao,
      duracaoMs: Date.now() - inicio,
      detalhe,
    };
    console.log(JSON.stringify(resultado));
    return responder(resultado, 200);
  } catch (erro) {
    // Status 500 explícito: é o que faz a execução aparecer como falha no
    // console do Neon. Engolir o erro aqui recriaria exatamente a falha
    // silenciosa que este job existe para eliminar.
    const resultado: Resultado = {
      ok: false,
      rota,
      invocacao,
      duracaoMs: Date.now() - inicio,
      erro: erro instanceof Error ? erro.message : String(erro),
    };
    console.error(JSON.stringify(resultado));
    return responder(resultado, 500);
  }
}
