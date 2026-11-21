import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const dir = new URL("../migrations/", import.meta.url);
const manifesto = readFileSync(new URL("manifest.txt", dir), "utf8")
  .split("\n")
  .map((linha) => linha.trim())
  .filter((linha) => linha && !linha.startsWith("#"));

test("manifesto: cada entrada existe e aparece uma vez", () => {
  assert.ok(manifesto.length > 0);
  assert.equal(new Set(manifesto).size, manifesto.length);
  for (const nome of manifesto) assert.ok(existsSync(new URL(`${nome}.sql`, dir)), `${nome}.sql não existe`);
});

test("manifesto: está em ordem numérica", () => {
  assert.deepEqual([...manifesto].sort(), manifesto);
});

test("manifesto: toda migration a partir da 015 está listada", () => {
  // 010..013 são do particionamento (benchmark/run.sh); 014 já está no schema-neon.sql.
  const arquivos = readdirSync(dir)
    .filter((f) => /^\d{3}_.+\.sql$/.test(f) && Number(f.slice(0, 3)) >= 15)
    .map((f) => f.replace(/\.sql$/, ""));
  assert.deepEqual(arquivos.sort(), [...manifesto].sort());
});
