import { DurableObject } from "cloudflare:workers";
import { MAX_BODY, requestFrames, ResponseAssembler, type Frame } from "./protocol";

export interface Env {
  DEVICE: DurableObjectNamespace<DeviceSession>;
}

const TIMEOUT_MS = 120_000;
const RATE_PER_MIN = 600;

// Заголовки, которые не передаём через посредника (относятся к одному соединению).
const DROP_REQ = new Set(["host", "connection", "upgrade", "keep-alive", "transfer-encoding", "content-length", "accept-encoding"]);
const DROP_RES = new Set(["connection", "keep-alive", "transfer-encoding", "content-length"]);

type Pending = { asm: ResponseAssembler; resolve: (r: Response) => void; timer: ReturnType<typeof setTimeout> };

/// Одна сессия = один айфон. Хранит хэш секрета айфона, держит его WebSocket и пересылает HTTP-запросы в него.
export class DeviceSession extends DurableObject<Env> {
  private pending = new Map<string, Pending>();
  private windowStart = 0;
  private windowCount = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Ping от айфона отвечает сам Cloudflare: объект не просыпается и запрос не считается.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS device (secret_hash TEXT NOT NULL, created INTEGER NOT NULL)");
  }

  /// Запоминает хэш секрета нового айфона. false — такой id уже занят.
  async init(secretHash: string): Promise<boolean> {
    const rows = this.ctx.storage.sql.exec("SELECT 1 FROM device").toArray();
    if (rows.length > 0) return false;
    this.ctx.storage.sql.exec("INSERT INTO device (secret_hash, created) VALUES (?, ?)", secretHash, Date.now());
    return true;
  }

  private secretHash(): string | null {
    const rows = this.ctx.storage.sql.exec<{ secret_hash: string }>("SELECT secret_hash FROM device").toArray();
    return rows[0]?.secret_hash ?? null;
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/__connect") return this.acceptDevice(req);
    return this.forward(req, url);
  }

  // MARK: - Айфон подключается

  private async acceptDevice(req: Request): Promise<Response> {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return json({ error: "Expected WebSocket" }, 426);
    const stored = this.secretHash();
    const given = bearer(req.headers.get("authorization"));
    if (!stored || !given || !equal(await sha256(given), stored)) return json({ error: "Unknown device or wrong secret" }, 401);

    // Новое подключение заменяет старое (айфон переподключился).
    for (const old of this.ctx.getWebSockets()) old.close(4000, "replaced");
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  // MARK: - Запрос от Claude или браузера → айфон

  private async forward(req: Request, url: URL): Promise<Response> {
    if (!this.secretHash()) return json({ error: "Unknown device. Check the address in the iPhone app." }, 404);
    const ws = this.ctx.getWebSockets()[0];
    if (!ws) return json({ error: "iPhone is offline. Open Lottie Developer on the iPhone and keep it on screen." }, 503);
    if (!this.allow()) return json({ error: "Too many requests. Wait a minute." }, 429);

    const body = new Uint8Array(await req.arrayBuffer());
    if (body.length > MAX_BODY) return json({ error: "Body is larger than 100 MB" }, 413);

    const headers: Record<string, string> = {};
    req.headers.forEach((v, k) => { if (!DROP_REQ.has(k) && !k.startsWith("cf-") && !k.startsWith("x-forwarded")) headers[k] = v; });

    const id = crypto.randomUUID();
    const response = new Promise<Response>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve(json({ error: "iPhone did not answer in 120 s" }, 504));
      }, TIMEOUT_MS);
      this.pending.set(id, { asm: new ResponseAssembler(), resolve, timer });
    });
    try {
      for (const f of requestFrames(id, req.method, url.pathname, url.search.slice(1), headers, body)) ws.send(f);
    } catch {
      this.finish(id, json({ error: "iPhone connection dropped" }, 502));
    }
    return response;
  }

  private allow(): boolean {
    const now = Date.now();
    if (now - this.windowStart > 60_000) { this.windowStart = now; this.windowCount = 0; }
    return ++this.windowCount <= RATE_PER_MIN;
  }

  private finish(id: string, r: Response) {
    const p = this.pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    p.resolve(r);
  }

  // MARK: - Ответы айфона

  async webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string") return;
    let f: Frame;
    try { f = JSON.parse(message); } catch { return; }
    if (f.t !== "res" && f.t !== "res-body") return;
    const p = this.pending.get(f.id);
    if (!p) return;
    if (!p.asm.add(f)) { this.finish(f.id, json({ error: "Response is larger than 100 MB" }, 502)); return; }
    if (!p.asm.done) return;
    const headers = new Headers();
    for (const [k, v] of Object.entries(p.asm.headers)) if (!DROP_RES.has(k.toLowerCase())) headers.set(k, v);
    const status = p.asm.status;
    const nullBody = status === 101 || status === 204 || status === 205 || status === 304;
    this.finish(f.id, new Response(nullBody ? null : (p.asm.body() as Uint8Array<ArrayBuffer>), { status, headers }));
  }

  async webSocketClose(ws: WebSocket, code: number) {
    if (this.ctx.getWebSockets().filter((s) => s !== ws).length > 0) return;
    for (const id of [...this.pending.keys()]) this.finish(id, json({ error: "iPhone disconnected" }, 502));
    try { ws.close(code === 1005 ? 1000 : code); } catch {}
  }
}

export function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
}

export function bearer(h: string | null): string | null {
  const m = h?.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

export async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function equal(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
