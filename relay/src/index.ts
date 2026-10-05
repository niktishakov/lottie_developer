// Посредник Lottie Developer: Claude на ПК → https → этот Worker → WebSocket → айфон.
// Адрес айфона: /d/<deviceId>/mcp. Браузер после /d/<deviceId>/ ходит по обычным путям, айфон выбирается по cookie.

import { DeviceSession, json, sha256, type Env } from "./session";

export { DeviceSession };

const DEVICE_RE = /^[a-z2-7]{20}$/;
const COOKIE = "lottie_device";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;

    if (req.method === "OPTIONS") return cors();
    if (p === "/health") return json({ ok: true });
    if (p === "/register" && req.method === "POST") return register(env, url);

    const m = p.match(/^\/d\/([^/]+)(\/.*)?$/);
    if (m) {
      const id = m[1];
      if (!DEVICE_RE.test(id)) return json({ error: "Bad device id" }, 400);
      const rest = m[2] ?? "/";
      const stub = env.DEVICE.get(env.DEVICE.idFromName(id));
      if (rest === "/connect") return stub.fetch(new Request("https://device/__connect", req));
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
