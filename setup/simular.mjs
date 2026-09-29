// Simulador de estações gravando DIRETO no banco (sem MQTT, Redis e recepção).
//
//   npm run db:simular                        -> preenche o buraco e segue a cada 60 s
//   npm run db:simular -- --uma-vez           -> um ciclo só e sai
//   npm run db:simular -- --intervalo 30      -> ciclo a cada 30 s
//   npm run db:simular -- --historico 24      -> preenche no máximo 24 h para trás (0 = não preenche)
//   npm run db:simular -- --todas             -> inclui as estações que o demo deixa Offline
//   npm run db:simular -- postgresql://...    -> outro banco (senão usa DATABASE_URL do .env)
//
// Faz o mesmo que o recepcao-persist faria com uma leitura da estação:
//   - INSERT em readings (sem duplicar sensor_id + unix_time)
//   - UPDATE de stations.last_communication_at (status Online no front)
// O motor de regras do serviço de alertas enxerga essas leituras normalmente.
//
// Quais estações: todas que têm sensor operacional. Por padrão ficam de fora as
// estações 05, 10 e 15 do seed-demo (MAC 00:1A:2B:3C:4D:05/10/15), que existem
// para aparecer Offline / nunca comunicou. --todas inclui essas também.
//
// Os valores são aleatórios, mas dentro do normal: cada execução sorteia um
// perfil por estação, os valores seguem o ciclo do dia (horário de Brasília),
// continuam a partir da última leitura do sensor e ficam dentro da faixa de
// cada tipo (Temperatura, Umidade, Pressão, Vento, Chuva, solo).

import "dotenv/config";
import pg from "pg";

// ---------------------------------------------------------------- argumentos
const limpar = (valor) => (valor ?? "").trim().replace(/^[<"']+|[>"']+$/g, "");
const args = process.argv.slice(2).map(limpar);
const valorDe = (flag, padrao) => {
  const i = args.indexOf(flag);
  if (i === -1) return padrao;
  const n = Number(args[i + 1]);
  if (!Number.isFinite(n) || n < 0) {
    console.error(`Valor inválido para ${flag}: ${args[i + 1]}`);
    process.exit(1);
  }
  return n;
};

const url = args.find((a) => a.startsWith("postgres")) ?? limpar(process.env.DATABASE_URL);
const UMA_VEZ = args.includes("--uma-vez");
const TODAS = args.includes("--todas");
const INTERVALO_S = valorDe("--intervalo", 60);
const HISTORICO_H = Math.min(valorDe("--historico", 168), 24 * 30);
const PASSO_HISTORICO_S = 600; // mesmo passo do seed-demo: uma leitura a cada 10 min

const MACS_OFFLINE_DEMO = ["00:1A:2B:3C:4D:05", "00:1A:2B:3C:4D:10", "00:1A:2B:3C:4D:15"];

if (!url) {
  console.error(
    "Faltou a DATABASE_URL.\n" +
      "  Crie um .env nesta pasta com DATABASE_URL=..., ou passe a URL como argumento:\n" +
      "  npm run db:simular -- postgresql://postgres:postgres@localhost:5433/vulture",
  );
  process.exit(1);
}
if (INTERVALO_S < 5 && !UMA_VEZ) {
  console.error("--intervalo mínimo é 5 segundos.");
  process.exit(1);
}

// ---------------------------------------------------------------- geração dos valores
// Cada execução sorteia um "perfil" por estação (mais quente, mais úmida, mais
// ventosa, mais chuvosa...), então os dados mudam a cada vez que o script roda.
// Os valores seguem o ciclo do dia e andam aos poucos a partir da leitura
// anterior do sensor, sem saltos, e nunca saem da faixa normal do tipo.
const round = (v) => Math.round(v * 100) / 100;
const rand = (min, max) => min + Math.random() * (max - min);
const ruido = (amp) => (Math.random() - 0.5) * amp;
const clamp = (v, [min, max]) => Math.min(max, Math.max(min, v));

const FAIXAS = {
  temp: [8, 38], // °C
  umid: [25, 100], // %
  pressao: [1000, 1026], // hPa
  vento: [0, 45], // km/h
  chuva: [0, 12], // mm por leitura
  temp_solo: [12, 32], // °C
  umid_solo: [15, 60], // %
};

const normalizar = (s) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();

function tipoDe(nome) {
  const t = normalizar(nome);
  if (t.includes("solo") && t.startsWith("temperatura")) return "temp_solo";
  if (t.includes("solo") && t.startsWith("umidade")) return "umid_solo";
  if (t.startsWith("temperatura")) return "temp";
  if (t.startsWith("umidade")) return "umid";
  if (t.startsWith("pressao")) return "pressao";
  if (t.includes("vento")) return "vento";
  if (t.includes("pluvio") || t.includes("chuva")) return "chuva";
  return null;
}

/** Hora decimal em Brasília (UTC-3, sem horário de verão). */
function horaLocal(unix) {
  const d = new Date(unix * 1000);
  return ((d.getUTCHours() + 21) % 24) + d.getUTCMinutes() / 60;
}

const perfis = new Map();
function perfil(estacaoId) {
  if (!perfis.has(estacaoId)) {
    perfis.set(estacaoId, {
      temp: rand(-3, 3), // estação mais fria ou mais quente
      umid: rand(-10, 10),
      pressao: rand(-4, 4),
      vento: rand(0.6, 1.6), // multiplicador do vento
      chuva: rand(0.05, 0.3), // chance de começar a chover a cada 6 h
      solo: rand(-6, 6),
      chovendo: false,
      chuvaIntensidade: 0,
      chuvaAte: 0,
    });
  }
  return perfis.get(estacaoId);
}

/** Atualiza (uma vez por estação e instante) se está chovendo. */
function atualizarChuva(p, unix, dt) {
  if (p.chuvaAte === unix) return;
  const passos = dt / 600;
  if (p.chovendo) {
    if (Math.random() < 1 - Math.pow(0.85, passos)) p.chovendo = false;
  } else if (Math.random() < 1 - Math.pow(1 - p.chuva / 36, passos)) {
    p.chovendo = true;
    p.chuvaIntensidade = rand(0.3, 3.5); // mm a cada 10 min
  }
  p.chuvaAte = unix;
}

/**
 * Próximo valor do sensor. prev = { value, unix } da leitura anterior (ou nulo).
 * Anda em direção ao "alvo" do horário com constante de tempo `tau` segundos.
 */
function gerarValor(sensor, unix, prev) {
  const tipo = tipoDe(sensor.tipo);
  const p = perfil(sensor.station_id);
  const dt = prev ? Math.max(60, unix - prev.unix) : 600;
  atualizarChuva(p, unix, dt);

  const h = horaLocal(unix);
  const ciclo = (pico) => Math.sin((2 * Math.PI * (h - pico)) / 24);
  const escala = Math.sqrt(Math.min(dt, 3600) / 600); // ruído proporcional ao intervalo

  if (tipo === "chuva") {
    return p.chovendo
      ? round(clamp(p.chuvaIntensidade * (Math.min(dt, 600) / 600) * rand(0.5, 1.5), FAIXAS.chuva))
      : 0;
  }

  let alvo;
  let tau;
  let amp;
  switch (tipo) {
    case "temp":
      alvo = 22 + p.temp + 6.5 * ciclo(9) - (p.chovendo ? 3 : 0);
      tau = 1800; amp = 0.8; break;
    case "umid":
      alvo = 68 + p.umid - 22 * ciclo(9) + (p.chovendo ? 22 : 0);
      tau = 1800; amp = 3; break;
    case "pressao":
      alvo = 1013 + p.pressao + 1.2 * Math.sin((4 * Math.PI * (h - 10)) / 24);
      tau = 3600; amp = 0.3; break;
    case "vento":
      alvo = (7 + 5 * ciclo(12)) * p.vento + (p.chovendo ? 6 : 0);
      tau = 900; amp = 4; break;
    case "temp_solo":
      alvo = 21 + p.solo * 0.4 + 3 * ciclo(11);
      tau = 3600; amp = 0.3; break;
    case "umid_solo":
      alvo = 36 + p.solo + (p.chovendo ? 12 : 0);
      tau = 6 * 3600; amp = 0.4; break;
    default: {
      // Tipo cadastrado pelo time que o simulador não conhece: passeia em volta do último valor.
      const base = prev?.value ?? 50;
      return round(base + ruido(Math.max(0.5, Math.abs(base) * 0.02)));
    }
  }

  // Sem leitura anterior recente (mais de 3 h), começa perto do alvo.
  const anterior = prev && unix - prev.unix <= 3 * 3600 ? prev.value : alvo + ruido(amp * 2);
  const peso = 1 - Math.exp(-dt / tau);
  const valor = anterior + (alvo - anterior) * peso + ruido(amp) * escala;
  return round(clamp(tipo === "vento" ? Math.max(0, valor) : valor, FAIXAS[tipo]));
}

// ---------------------------------------------------------------- banco
const pool = new pg.Pool({ connectionString: url, max: 2, connectionTimeoutMillis: 20000 });

async function carregarSensores(client) {
  const { rows } = await client.query(
    `SELECT s.id, s.station_id, st.mac_address, st.name AS estacao, t.name AS tipo,
            ult.value::float8 AS ultimo_valor, ult.unix_time::float8 AS ultimo_unix
       FROM sensors s
       JOIN stations st ON st.id = s.station_id
       JOIN sensor_types t ON t.id = s.sensor_type_id
       LEFT JOIN LATERAL (
         SELECT r.value, r.unix_time FROM readings r
          WHERE r.sensor_id = s.id
          ORDER BY r.unix_time DESC LIMIT 1
       ) ult ON true
      WHERE s.operational_status
        AND ($1::boolean OR upper(st.mac_address) <> ALL($2::text[]))
      ORDER BY s.station_id, s.id`,
    [TODAS, MACS_OFFLINE_DEMO],
  );
  return rows;
}

const LOTE = 5000;

async function gravar(client, linhas) {
  let inseridas = 0;
  for (let i = 0; i < linhas.length; i += LOTE) {
    const parte = linhas.slice(i, i + LOTE);
    // Mesmo NOT EXISTS do recepcao-persist: rodar de novo não duplica.
    const res = await client.query(
      `INSERT INTO readings (sensor_id, value, unix_time)
       SELECT n.sensor_id, n.value, n.unix_time
         FROM unnest($1::int[], $2::float8[], $3::bigint[]) AS n(sensor_id, value, unix_time)
        WHERE NOT EXISTS (
          SELECT 1 FROM readings r WHERE r.sensor_id = n.sensor_id AND r.unix_time = n.unix_time)`,
      [parte.map((l) => l.sensor_id), parte.map((l) => l.value), parte.map((l) => l.unix_time)],
    );
    inseridas += res.rowCount;
  }
  return inseridas;
}

async function atualizarComunicacao(client, ultimaPorEstacao) {
  if (ultimaPorEstacao.size === 0) return;
  await client.query(
    `UPDATE stations st
        SET last_communication_at = GREATEST(COALESCE(st.last_communication_at, 'epoch'),
                                             to_timestamp(n.unix_time) AT TIME ZONE 'UTC')
       FROM unnest($1::int[], $2::bigint[]) AS n(station_id, unix_time)
      WHERE st.id = n.station_id`,
    [[...ultimaPorEstacao.keys()], [...ultimaPorEstacao.values()]],
  );
}

async function emTransacao(fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const resultado = await fn(client);
    await client.query("COMMIT");
    return resultado;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------- etapas
/** Preenche de 10 em 10 min, da última leitura de cada sensor até agora. */
async function preencherHistorico() {
  if (HISTORICO_H === 0) return;
  const agora = Math.floor(Date.now() / 1000);
  const inicioMaximo = agora - HISTORICO_H * 3600;

  await emTransacao(async (client) => {
    const sensores = await carregarSensores(client);
    const linhas = [];
    const ultimaPorEstacao = new Map();

    for (const sensor of sensores) {
      // Alinha no passo de 10 min, como o seed-demo.
      const desde = Math.max(inicioMaximo, (sensor.ultimo_unix ?? inicioMaximo) + 1);
      let t = Math.ceil(desde / PASSO_HISTORICO_S) * PASSO_HISTORICO_S;
      let prev = sensor.ultimo_unix ? { value: sensor.ultimo_valor, unix: sensor.ultimo_unix } : null;
      for (; t < agora - 30; t += PASSO_HISTORICO_S) {
        const value = gerarValor(sensor, t, prev);
        prev = { value, unix: t };
        linhas.push({ sensor_id: sensor.id, value, unix_time: t });
        ultimaPorEstacao.set(sensor.station_id, Math.max(ultimaPorEstacao.get(sensor.station_id) ?? 0, t));
      }
    }

    if (linhas.length === 0) {
      console.log("[simular] histórico já está em dia, nada a preencher");
      return;
    }
    const inseridas = await gravar(client, linhas);
    await atualizarComunicacao(client, ultimaPorEstacao);
    console.log(
      `[simular] histórico preenchido: ${inseridas} leituras em ${ultimaPorEstacao.size} estação(ões) ` +
        `(até ${HISTORICO_H} h para trás)`,
    );
  });
}

async function ciclo() {
  const agora = Math.floor(Date.now() / 1000);
  const { inseridas, estacoes } = await emTransacao(async (client) => {
    const sensores = await carregarSensores(client);
    const linhas = sensores.map((sensor) => ({
      sensor_id: sensor.id,
      value: gerarValor(
        sensor,
        agora,
        sensor.ultimo_unix ? { value: sensor.ultimo_valor, unix: sensor.ultimo_unix } : null,
      ),
      unix_time: agora,
    }));
    const ultimaPorEstacao = new Map(sensores.map((s) => [s.station_id, agora]));
    const n = await gravar(client, linhas);
    await atualizarComunicacao(client, ultimaPorEstacao);
    return { inseridas: n, estacoes: ultimaPorEstacao.size };
  });
  console.log(`[simular] ${new Date().toISOString()} ${inseridas} leituras em ${estacoes} estação(ões)`);
}

// ---------------------------------------------------------------- execução
try {
  const { rows } = await pool.query("SELECT current_database() AS db");
  const alvo = new URL(url.replace(/^postgres(ql)?:/, "http:")).host;
  console.log(`[simular] banco "${rows[0].db}" em ${alvo}`);
  if (alvo.includes("neon.tech")) {
    console.log("[simular] ATENÇÃO: Neon é compartilhado, o time inteiro vai ver essas leituras.");
  }

  const { rows: est } = await pool.query(
    `SELECT count(DISTINCT s.station_id)::int AS n FROM sensors s
       JOIN stations st ON st.id = s.station_id
      WHERE s.operational_status AND ($1::boolean OR upper(st.mac_address) <> ALL($2::text[]))`,
    [TODAS, MACS_OFFLINE_DEMO],
  );
  if (est[0].n === 0) {
    console.error(
      "[simular] nenhuma estação com sensor operacional. Cadastre estações e sensores " +
        "(ou rode o seed-demo.sql num banco local) antes de simular.",
    );
    process.exit(1);
  }
  console.log(`[simular] ${est[0].n} estação(ões) com sensores${TODAS ? " (--todas)" : ""}`);

  await preencherHistorico();
  await ciclo();
} catch (error) {
  console.error("[simular] FALHOU:", error instanceof Error ? error.message : String(error));
  await pool.end().catch(() => {});
  process.exit(1);
}

if (UMA_VEZ) {
  await pool.end();
} else {
  console.log(`[simular] gravando a cada ${INTERVALO_S} s. Ctrl+C para parar.`);
  const timer = setInterval(() => {
    ciclo().catch((error) =>
      console.error("[simular] ciclo falhou:", error instanceof Error ? error.message : String(error)),
    );
  }, INTERVALO_S * 1000);

  const parar = async () => {
    clearInterval(timer);
    await pool.end().catch(() => {});
    console.log("\n[simular] parado.");
    process.exit(0);
  };
  process.on("SIGINT", parar);
  process.on("SIGTERM", parar);
}