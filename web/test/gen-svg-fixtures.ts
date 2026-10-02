// Генерация golden-фикстур: SVG → Lottie через Swift lottie-mcp (create_project → get_geometry → delete_project).
// Запуск: bun test/gen-svg-fixtures.ts [имя.svg ...]   (по умолчанию — все test/fixtures/svg/*.svg)
import { readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const BIN = resolve(import.meta.dir, "../../build/dd/Build/Products/Debug/lottie-mcp");
const DIR = join(import.meta.dir, "fixtures/svg");

const proc = Bun.spawn([BIN], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const reader = proc.stdout.getReader();
let buf = "";
let nextId = 1;
const pending = new Map<number, (v: any) => void>();

(async () => {
  const dec = new TextDecoder();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      const msg = JSON.parse(line);
      if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)!(msg); pending.delete(msg.id); }
    }
  }
})();

function send(obj: any) { proc.stdin.write(JSON.stringify(obj) + "\n"); proc.stdin.flush(); }
function rpc(method: string, params: any): Promise<any> {
  const id = nextId++;
  return new Promise((res) => { pending.set(id, res); send({ jsonrpc: "2.0", id, method, params }); });
}
async function tool(name: string, args: any): Promise<any> {
  const r = await rpc("tools/call", { name, arguments: args });
  if (r.error) throw new Error(`${name}: ${JSON.stringify(r.error)}`);
  const text = r.result?.content?.[0]?.text ?? "";
  if (r.result?.isError) throw new Error(`${name}: ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

await rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "gen-svg-fixtures", version: "1" } });
send({ jsonrpc: "2.0", method: "notifications/initialized" });

const files = process.argv.slice(2).length ? process.argv.slice(2) : readdirSync(DIR).filter((f) => f.endsWith(".svg")).sort();
for (const f of files) {
  const base = f.replace(/\.svg$/, "");
  const projectID = `golden-svg-${base.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
  let created = false;
  try {
    const c = await tool("create_project", { name: projectID, svg_path: join(DIR, f), show_in_app: false });
    created = true;
    const pid = projectID;
    const g = await tool("get_geometry", { project_id: pid, include_lottie: true });
    const out = { layerNames: c.project?.layers ?? [], warnings: c.svgWarnings ?? [], lottie: g.lottie };
    writeFileSync(join(DIR, `${base}.lottie.json`), JSON.stringify(out, null, 1) + "\n");
    console.log(`ok ${f}`);
    await tool("delete_project", { project_id: pid });
    created = false;
  } catch (e) {
    console.error(`FAIL ${f}: ${(e as Error).message}`);
    if (created) await tool("delete_project", { project_id: projectID }).catch(() => {});
  }
}
proc.stdin.end();
proc.kill();
