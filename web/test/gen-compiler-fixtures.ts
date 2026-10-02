// Генерирует golden-фикстуры компилятора через Swift MCP-сервер (lottie-mcp).
//
//   cd web && bun run test/gen-compiler-fixtures.ts [path/to/lottie-mcp]
//
// Создаёт временные проекты golden-* и всегда удаляет их в конце. Пишет web/test/fixtures/compiler/*.json.

import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cases, fixturesDir, inputs, inspectInputs, repoRoot, specErrorCases, specOkCases, syntheticInputs } from "./compiler-cases";

const binary = process.argv[2] ?? join(repoRoot, "build/dd/Build/Products/Debug/lottie-mcp");

// MARK: - JSON-RPC over stdio

const proc = Bun.spawn([binary], { stdin: "pipe", stdout: "pipe", stderr: "ignore" });
const reader = proc.stdout.getReader();
const decoder = new TextDecoder();
let buffer = "";
let nextId = 1;

async function readLine(): Promise<string> {
  for (;;) {
    const nl = buffer.indexOf("\n");
    if (nl >= 0) {
      const line = buffer.slice(0, nl);
      buffer = buffer.slice(nl + 1);
      if (line.trim()) return line;
      continue;
    }
    const { value, done } = await reader.read();
    if (done) throw new Error("lottie-mcp closed stdout");
    buffer += decoder.decode(value, { stream: true });
  }
}

async function call(name: string, args: Record<string, unknown>): Promise<{ isError: boolean; text: string }> {
  const id = nextId++;
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }) + "\n");
  await proc.stdin.flush();
  const msg = JSON.parse(await readLine());
  if (msg.id !== id) throw new Error(`unexpected response id ${msg.id} (want ${id})`);
  if (msg.error) throw new Error(`${name}: ${JSON.stringify(msg.error)}`);
  return { isError: !!msg.result.isError, text: msg.result.content[0].text };
}

async function callJSON(name: string, args: Record<string, unknown>): Promise<any> {
  const r = await call(name, args);
  if (r.isError) throw new Error(`${name} failed: ${r.text}`);
  return JSON.parse(r.text);
}

// MARK: - Helpers

function close(a: any, b: any, path = ""): string | null {
  if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) <= 1e-6 ? null : `${path}: ${a} != ${b}`;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return `${path}: length ${a.length} != ${b.length}`;
    for (let i = 0; i < a.length; i++) { const d = close(a[i], b[i], `${path}[${i}]`); if (d) return d; }
    return null;
  }
  if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
    const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
    if (ka.join("\u0000") !== kb.join("\u0000")) return `${path}: keys ${ka} != ${kb}`;
    for (const k of ka) { const d = close(a[k], b[k], `${path}.${k}`); if (d) return d; }
    return null;
  }
  return a === b ? null : `${path}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`;
}

// Кейсы пишем компактно (в них целые Lottie), служебные фикстуры — читаемо.
const write = (file: string, data: unknown) => writeFileSync(join(fixturesDir, file), JSON.stringify(data) + "\n");

const created: string[] = [];
async function createProject(name: string, lottiePath: string): Promise<void> {
  await callJSON("create_project", { name, lottie_path: lottiePath, show_in_app: false });
  created.push(name);
}

// MARK: - Main

async function main(): Promise<void> {
  mkdirSync(join(fixturesDir, "inputs"), { recursive: true });
  for (const f of readdirSync(fixturesDir)) if (f.endsWith(".json")) rmSync(join(fixturesDir, f));
  for (const [key, make] of Object.entries(syntheticInputs)) {
    writeFileSync(inputs[key]!, JSON.stringify(make(), null, 1) + "\n");
  }

  // Проекты на каждый вход + проверка, что Swift хранит геометрию без изменений.
  const inputAnimations: Record<string, string | null> = {};
  for (const [key, file] of Object.entries(inputs)) {
    const project = `golden-${key}`;
    await createProject(project, file);
    const geo = await callJSON("get_geometry", { project_id: project, include_lottie: true });
    const diff = close(geo.lottie, JSON.parse(await Bun.file(file).text()));
    if (diff) throw new Error(`stored geometry for ${key} differs from input: ${diff}`);
    inputAnimations[key] = geo.animations;
  }

  await createProject("golden-inspect", inputs.minimal!);
  const inspect = async (lottie: unknown): Promise<string | null> => {
    await callJSON("replace_geometry", { project_id: "golden-inspect", lottie });
    const geo = await callJSON("get_geometry", { project_id: "golden-inspect", include_lottie: true });
    const diff = close(geo.lottie, lottie);
    if (diff) throw new Error(`inspect geometry roundtrip differs: ${diff}`);
    return geo.animations;
  };

  const names = new Set<string>();
  for (const c of cases) {
    if (names.has(c.name)) throw new Error(`duplicate case name ${c.name}`);
    names.add(c.name);
    const out = await callJSON("validate_spec", { project_id: `golden-${c.input}`, spec: c.spec, include_lottie: true });
    const animations = await inspect(out.lottie);
    write(`${c.name}.json`, { name: c.name, input: c.input, spec: c.spec, warnings: out.warnings, animations, lottie: out.lottie });
    console.log(`case ${c.name}: ${out.warnings.length} warnings`);
  }

  const inspectFixtures: { name: string; lottie: unknown; animations: string | null }[] = [];
  for (const [key, animations] of Object.entries(inputAnimations)) inspectFixtures.push({ name: `input:${key}`, lottie: null, animations });
  for (const ii of inspectInputs) inspectFixtures.push({ name: ii.name, lottie: ii.lottie, animations: await inspect(ii.lottie) });
  writeFileSync(join(fixturesDir, "_inspect.json"), JSON.stringify(inspectFixtures, null, 1) + "\n");

  const prefix = "Error: Invalid AnimationSpec: ";
  const specResults: { spec: unknown; error: string | null }[] = [];
  for (const spec of [...specErrorCases, ...specOkCases]) {
    const r = await call("validate_spec", { project_id: "golden-minimal", spec });
    if (r.isError && !r.text.startsWith(prefix)) throw new Error(`unexpected error: ${r.text}`);
    specResults.push({ spec, error: r.isError ? r.text.slice(prefix.length) : null });
  }
  writeFileSync(join(fixturesDir, "_spec-parse.json"), JSON.stringify(specResults, null, 1) + "\n");

  const guide = await callJSON("get_guide", {});
  writeFileSync(join(fixturesDir, "_schema.json"), JSON.stringify(guide.schema, null, 1) + "\n");
  console.log(`wrote ${cases.length} cases, ${inspectFixtures.length} inspect, ${specResults.length} spec-parse fixtures`);
}

try {
  await main();
} finally {
  for (const project of created) {
    try { await callJSON("delete_project", { project_id: project }); } catch (e) { console.error(`failed to delete ${project}:`, e); }
  }
  proc.stdin.end();
  await proc.exited;
}
