// Локальный просмотрщик для дизайнера: http://127.0.0.1:7357 — проекты, плеер (lottie-web), версии, таймлайн.
// Живой: страница опрашивает /api/poll и подхватывает изменения из MCP (новые версии, show_in_app).
import { statSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { platform } from "node:os";
import type { Store } from "./store.ts";
import { uuid, now } from "./store.ts";
import type { Tools } from "./mcp.ts";
import { readBundle } from "../core/bundle.ts";
import { pixelSize } from "../core/images.ts";
import { writeFileSync, mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { extname } from "node:path";
import indexHtml from "../viewer/index.html" with { type: "text" };
import lottieJs from "lottie-web/build/player/lottie.min.js" with { type: "text" };

export const PORT = Number(process.env.LOTTIE_DEV_PORT ?? 7357);
export const viewerURL = () => `http://127.0.0.1:${PORT}`;

export function openBrowser(path = "") {
  const url = viewerURL() + path;
  const [cmd, args] = platform() === "win32" ? ["cmd", ["/c", "start", "", url]]
    : platform() === "darwin" ? ["open", [url]] : ["xdg-open", [url]];
  try { spawn(cmd, args as string[], { detached: true, stdio: "ignore" }).unref(); } catch {}
}

/** Подпись состояния диска: меняется, когда MCP (или Mac-приложение) что-то записали. */
function signature(store: Store): string {
  const parts: string[] = [];
  for (const id of readdirSync(store.root)) {
    for (const f of ["project.json", "feedback.json", "assets"]) {
      const p = join(store.root, id, f);
      if (existsSync(p)) parts.push(`${id}/${f}:${statSync(p).mtimeMs}`);
    }
  }
  return String(Bun.hash(parts.sort().join("|")));
}

const MIME: Record<string, string> = { svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", json: "application/json" };

export function startViewer(store: Store, tools: Tools): boolean {
  const json = (v: any, status = 200) => new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });
  /** Действие через тот же код, что у MCP-инструментов: ошибки → 400 с текстом. */
  const act = async (name: string, args: any) => {
    try { return json((await tools.call(name, args)).json); } catch (e: any) { return json({ error: e?.message ?? String(e) }, 400); }
  };
  try {
    Bun.serve({
      port: PORT, hostname: "127.0.0.1",
      async fetch(req) {
        const url = new URL(req.url);
        const p = url.pathname;
        if (p === "/" || p.startsWith("/p/")) return new Response(indexHtml as unknown as string, { headers: { "content-type": "text/html; charset=utf-8" } });
        if (p === "/lottie.js") return new Response(lottieJs, { headers: { "content-type": "text/javascript" } });
        if (p === "/api/poll") return json({ sig: signature(store), command: store.uiCommand() });
        if (p === "/api/projects") return json(store.projects());
        if (p === "/api/state" && req.method === "POST") { store.writeAppState(await req.json()); return json({ ok: true }); }
        // --- этап 2: ассеты, правки, комментарии ---
        const a = p.match(/^\/api\/project\/([0-9A-F-]+)\/(assets|asset|upload|place|edits|feedback|feedback-resolve|feedback-delete)$/i);
        if (a) {
          const proj = store.project(a[1]);
          if (!proj) return json({ error: "not found" }, 404);
          const id = proj.id;
          switch (a[2]) {
            case "assets": {
              const u = store.usage(id);
              const names = new Set(proj.layerNames);
              return json(store.assets(id).map((f) => ({ ...f, usedBy: (u[f.name] ?? []).filter((n) => names.has(n)),
                pixels: f.kind === "image" ? pixelSize(new Uint8Array(readFileSync(f.path))) : null })));
            }
            case "asset": {
              const name = url.searchParams.get("name") ?? "";
              if (req.method === "DELETE") return act("delete_asset", { project_id: id, name });
              const f = store.assets(id).find((x) => x.name === name);
              if (!f) return json({ error: "no asset" }, 404);
              return new Response(Bun.file(f.path), { headers: { "content-type": MIME[extname(name).slice(1).toLowerCase()] ?? "application/octet-stream" } });
            }
            case "upload": {
              // Тело — файл; имя — ?name=. zip распаковывается в папку ассетов.
              const name = url.searchParams.get("name") ?? "file";
              const bytes = new Uint8Array(await req.arrayBuffer());
              const added: string[] = [];
              if (/\.zip$/i.test(name)) {
                const dir = mkdtempSync(`${tmpdir()}/upload-`);
                try { writeFileSync(`${dir}/${name}`, bytes); for (const f of readBundle(`${dir}/${name}`)) added.push(store.writeAsset(id, f.name, f.data)); }
                finally { rmSync(dir, { recursive: true, force: true }); }
              } else added.push(store.writeAsset(id, name, bytes));
              return json({ added });
            }
            case "place": return act("place_asset", { project_id: id, ...(await req.json()) });
            case "edits": {
              const b = await req.json();
              return act("apply_overrides", { project_id: id, version: b.version ?? undefined, overrides: b.overrides,
                prompt: "Edits in viewer", note: b.note, show_in_app: false });
            }
            case "feedback": {
              if (req.method === "GET") return json(store.feedback(id));
              const b = await req.json();
              const items = store.feedback(id);
              items.push({ id: uuid(), versionID: b.versionID ?? undefined, versionLabel: b.versionLabel ?? "geometry",
                frame: Math.round(b.frame ?? 0), layer: b.layer ?? undefined, text: String(b.text ?? "").trim(), createdAt: now(), resolved: false });
              store.saveFeedback(id, items);
              return json({ ok: true });
            }
            case "feedback-resolve": {
              const b = await req.json();
              const items = store.feedback(id); const f = items.find((x) => x.id === b.id);
              if (f) { f.resolved = !!b.resolved; f.resolvedAt = f.resolved ? now() : undefined; store.saveFeedback(id, items); }
              return json({ ok: !!f });
            }
            case "feedback-delete": {
              const b = await req.json();
              store.saveFeedback(id, store.feedback(id).filter((x) => x.id !== b.id));
              return json({ ok: true });
            }
          }
        }
        const m = p.match(/^\/api\/project\/([0-9A-F-]+)(?:\/(geometry|version\/([0-9A-F-]+)))?$/i);
        if (m) {
          const proj = store.project(m[1]);
          if (!proj) return json({ error: "not found" }, 404);
          if (!m[2]) return json(proj);
          if (m[2] === "geometry") return json(store.geometry(proj));
          const v = proj.versions.find((x) => x.id === m[3]);
          return v ? json(store.versionLottie(proj.id, v)) : json({ error: "no version" }, 404);
        }
        return new Response("Not found", { status: 404 });
      },
    });
    return true;
  } catch {
    return false; // порт занят — скорее всего, его уже обслуживает другой экземпляр (другая сессия Claude)
  }
}
