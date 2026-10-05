// Посредник Lottie Developer: Claude на ПК → https → этот Worker → WebSocket → айфон.
// Адрес айфона: /d/<deviceId>/mcp. Браузер после /d/<deviceId>/ ходит по обычным путям, айфон выбирается по cookie.

import { PAIR_HTML } from "./pair-page";
import { DeviceSession, PinIndex, RegistrationQuota, json, sha256, type Env } from "./session";

export { DeviceSession, PinIndex, RegistrationQuota };

const DEVICE_RE = /^[a-z2-7]{20}$/;
const COOKIE = "lottie_device";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;

    if (req.method === "OPTIONS") return cors();
    if (p === "/health") return json({ ok: true });
    const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
    if (p === "/register" && req.method === "POST") {
      if (!(await env.REGISTER_LIMIT.limit({ key: ip })).success) return json({ error: "Too many registrations. Wait a minute." }, 429);
      return register(env, url);
    }
    // Короткий вход: только PIN, айфон находим по нему.
    if (p === "/pair") {
      if (req.method === "GET") return new Response(PAIR_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
      if (req.method === "POST") {
        if (!(await env.PAIR_LIMIT.limit({ key: ip })).success) return json({ error: "Too many attempts. Wait a minute and try again." }, 429);
        return pairByPin(req, env);
      }
    }
    // Лимит на IP до обращения к Durable Object: перебор адресов не тратит дневной лимит.
    if (!(await env.IP_LIMIT.limit({ key: ip })).success) return json({ error: "Too many requests. Wait a minute." }, 429);

    const m = p.match(/^\/d\/([^/]+)(\/.*)?$/);
    if (m) {
      const id = m[1];
      if (!DEVICE_RE.test(id)) return json({ error: "Bad device id" }, 400);
      const rest = m[2] ?? "/";
      const stub = env.DEVICE.get(env.DEVICE.idFromName(id));
      if (rest === "/connect") {
        const r = new Request("https://device/__connect", req);
        r.headers.set("x-device-id", id);
        return stub.fetch(r);
      }
      const res = await stub.fetch(inner(req, url, rest));
      return withDeviceCookie(res, id);
    }

    const id = cookie(req.headers.get("cookie"), COOKIE) ?? req.headers.get("x-lottie-device");
    if (id && DEVICE_RE.test(id)) {
      const stub = env.DEVICE.get(env.DEVICE.idFromName(id));
      return stub.fetch(inner(req, url, p));
    }
    return json({ error: "Open the address shown in the Lottie Developer iPhone app" }, 404);
  },
} satisfies ExportedHandler<Env>;

async function register(env: Env, url: URL): Promise<Response> {
  const quota = env.QUOTA.get(env.QUOTA.idFromName("global"));
  if (!(await quota.take())) return json({ error: "The relay is not accepting new devices today. Try again tomorrow." }, 503);
  for (let attempt = 0; attempt < 3; attempt++) {
    const deviceId = randomBase32(20);
    const secret = randomHex(32);
    const stub = env.DEVICE.get(env.DEVICE.idFromName(deviceId));
    if (await stub.init(await sha256(secret))) {
      return json({ deviceId, deviceSecret: secret, base: `${url.origin}/d/${deviceId}` });
    }
  }
  return json({ error: "Try again" }, 500);
}

async function pairByPin(req: Request, env: Env): Promise<Response> {
  const body = await req.text();
  let pin = "";
  try { pin = String(JSON.parse(body).pin ?? "").trim(); } catch {}
  if (!/^\d{6}$/.test(pin)) return json({ error: "Enter the 6-digit PIN" }, 400);
  const index = env.PINS.get(env.PINS.idFromName("global"));
  if (!(await index.allowed())) return json({ error: "Too many attempts. Wait a minute and try again." }, 429);
  for (const id of await index.lookup(pin)) {
    const stub = env.DEVICE.get(env.DEVICE.idFromName(id));
    const res = await stub.fetch(new Request("https://device/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ pin }) }));
    if (res.ok) return withDeviceCookie(res, id);
  }
  await index.fail();
  return json({ error: "Wrong PIN, or the iPhone app is closed. Open Lottie Developer on the iPhone and try again." }, 403);
}

function inner(req: Request, url: URL, path: string): Request {
  return new Request(`https://device${path}${url.search}`, req);
}

function withDeviceCookie(res: Response, id: string): Response {
  const r = new Response(res.body, res);
  r.headers.append("set-cookie", `${COOKIE}=${id}; Path=/; Max-Age=31536000; SameSite=Lax; Secure; HttpOnly`);
  return r;
}

function cors(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
      "access-control-allow-headers": "*",
      "access-control-max-age": "86400",
    },
  });
}

function cookie(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, v] = part.split("=").map((s) => s.trim());
    if (k === name && v) return v;
  }
  return null;
}

function randomBase32(n: number): string {
  const abc = "abcdefghijklmnopqrstuvwxyz234567";
  const bytes = crypto.getRandomValues(new Uint8Array(n));
  return [...bytes].map((b) => abc[b & 31]).join("");
}

function randomHex(n: number): string {
  return [...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, "0")).join("");
}
