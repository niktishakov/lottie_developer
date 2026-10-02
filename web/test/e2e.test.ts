// Сквозной тест MCP-сервера через stdio — как его запускает Claude. Данные — во временной папке.
import { test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type Subprocess } from "bun";

const SCAN_ZIP = join(import.meta.dir, "fixtures/e2e/scan.zip");
let home: string, proc: Subprocess<"pipe", "pipe", "pipe">, id = 0;
const pending = new Map<number, (v: any) => void>();

async function rpc(method: string, params: any = {}) {
  const myId = ++id;
  const p = new Promise<any>((r) => pending.set(myId, r));
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: myId, method, params }) + "\n");
  proc.stdin.flush();
  return p;
}
async function tool(name: string, args: any = {}) {
  const r = await rpc("tools/call", { name, arguments: args });
  const text = r.result.content[0].text;
  if (r.result.isError) throw new Error(text);
  return { json: JSON.parse(text), images: r.result.content.filter((c: any) => c.type === "image") };
}

beforeAll(async () => {
  home = mkdtempSync(join(tmpdir(), "lottie-e2e-"));
  proc = spawn(["bun", "run", join(import.meta.dir, "../src/server/main.ts")], {
    stdin: "pipe", stdout: "pipe", stderr: "pipe", env: { ...process.env, LOTTIE_DEV_HOME: home, LOTTIE_DEV_PORT: "17357" },
  });
  (async () => {
    let buf = "";
    for await (const chunk of proc.stdout) {
      buf += new TextDecoder().decode(chunk);
      let i;
      while ((i = buf.indexOf("\n")) >= 0) { const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1); pending.get(m.id)?.(m); }
    }
  })();
});
afterAll(() => { proc.kill(); rmSync(home, { recursive: true, force: true }); });

test("initialize + tools", async () => {
  const init = await rpc("initialize", { protocolVersion: "2025-06-18" });
  expect(init.result.serverInfo.name).toBe("lottie-developer");
  expect(init.result.instructions).toContain("viewer");
  const list = await rpc("tools/list");
  expect(list.result.tools.length).toBeGreaterThanOrEqual(34);
});

test("designer flow: bundle → layout → version → render → feedback → export", async () => {
  if (!existsSync(SCAN_ZIP)) throw new Error("fixture missing: " + SCAN_ZIP);
  const c = await tool("create_project", { bundle: SCAN_ZIP, name: "scan", show_in_app: false });
  expect(c.json.canvas).toEqual({ width: 393, height: 546 });
  expect(c.json.parts).toEqual(["Line", "Content", "Red square"]);

  const assets = await tool("list_assets", { project_id: "scan" });
  expect(assets.json.assets.map((a: any) => a.name).sort()).toEqual(["Content.svg", "Line.svg", "Red square.png"]);
  expect(assets.json.assets.find((a: any) => a.name === "Line.svg").usedBy).toEqual(["Line"]);

  await tool("place_layer", { project_id: "scan", layer: "Line", x: 0, y: -40 });
  await tool("rename_layer", { project_id: "scan", layer: "Red square", name: "flash" });

  const v = await tool("create_version", { project_id: "scan", prompt: "scan", note: "line sweeps", show_in_app: false,
    spec: { fps: 60, durationFrames: 120, layers: [{ target: "Line", animations: [{ kind: "followPath", start: 0, end: 1.6, easing: "easeInOut", params: { path: [[0, 0], [0, 100], [0, 0]] } }] }] } });
  expect(v.json.version.label).toBe("v1");

  const r = await tool("render_frame", { project_id: "scan", version: "latest", count: 3, size: 200 });
  expect(r.images.length).toBe(3);
  expect(r.json.frames.map((f: any) => f.frame)).toEqual([0, 60, 120]);

  // комментарий, как его пишет просмотрщик / Mac-приложение
  const p = (await tool("get_project", { project_id: "scan" })).json;
  writeFileSync(join(home, "projects", p.id, "feedback.json"), JSON.stringify([{ id: "F1", versionLabel: "v1", frame: 48, text: "slower", createdAt: "2026-01-01T00:00:00Z", resolved: false }]));
  const fb = await tool("get_feedback", {});
  expect(fb.json.count).toBe(1);
  await tool("resolve_feedback", { project_id: "scan", id: "F1", reply: "done in v2" });
  expect((await tool("get_feedback", { status: "resolved" })).json.items[0].reply).toBe("done in v2");

  const out = join(home, "final.json");
  await tool("export", { project_id: "scan", version: "v1", path: out });
  expect(existsSync(out)).toBe(true);

  const rv = await tool("restore_version", { project_id: "scan", version: "v1" });
  expect(rv.json.version.label).toBe("v2");
  const d = await tool("diff_versions", { project_id: "scan", from: "v1", to: "v2" });
  expect(d.json.specChanges).toEqual([]);
});
