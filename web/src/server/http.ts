// Локальный просмотрщик для дизайнера: http://127.0.0.1:7357 — проекты, плеер (lottie-web), версии, таймлайн.
// Живой: страница опрашивает /api/poll и подхватывает изменения из MCP (новые версии, show_in_app).
import { statSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { platform } from "node:os";
import type { Store } from "./store.ts";
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

export function startViewer(store: Store): boolean {
  const json = (v: any, status = 200) => new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });
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
        const m = p.match(/^\/api\/project\/([0-9A-F-]+)(?:\/(geometry|version\/([0-9A-F-]+)|feedback))?$/i);
        if (m) {
          const proj = store.project(m[1]);
          if (!proj) return json({ error: "not found" }, 404);
          if (!m[2]) return json(proj);
          if (m[2] === "geometry") return json(store.geometry(proj));
          if (m[2] === "feedback") return json(store.feedback(proj.id));
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
