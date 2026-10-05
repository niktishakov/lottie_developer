// Сквозная проверка без айфона: регистрируется, подключается и отвечает эхом.
// Запуск: RELAY=http://localhost:8787 npm run e2e
const RELAY = process.env.RELAY ?? "http://localhost:8787";
import { requestFrames } from "../src/protocol.ts";

const reg = await (await fetch(`${RELAY}/register`, { method: "POST" })).json() as { deviceId: string; deviceSecret: string; base: string };
console.log("registered", reg.base);

const wsURL = `${RELAY.replace(/^http/, "ws")}/d/${reg.deviceId}/connect`;
// @ts-ignore — у WebSocket в Node есть headers
const ws = new WebSocket(wsURL, { headers: { authorization: `Bearer ${reg.deviceSecret}` } });
const bodies = new Map<string, { head: any; parts: string[] }>();
ws.onmessage = (e) => {
  const f = JSON.parse(String(e.data));
  const cur = f.t === "req" ? { head: f, parts: [f.body] } : bodies.get(f.id)!;
  if (f.t === "req-body") cur.parts.push(f.body);
  bodies.set(f.id, cur);
  if (f.more) return;
  bodies.delete(f.id);
  const size = cur.parts.reduce((n, p) => n + Buffer.from(p, "base64").length, 0);
  const answer = new TextEncoder().encode(JSON.stringify({ method: cur.head.method, path: cur.head.path, query: cur.head.query, auth: cur.head.headers.authorization ?? null, size }));
  for (const s of requestFrames(f.id, "", "", "", {}, answer)) {
    const r = JSON.parse(s);
    ws.send(JSON.stringify(r.t === "req" ? { t: "res", id: f.id, status: 200, headers: { "content-type": "application/json" }, body: r.body, more: r.more } : { ...r, t: "res-body" }));
  }
};
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
console.log("connected");

const check = async (name: string, init: RequestInit, path = "/mcp?x=1") => {
  const r = await fetch(`${reg.base}${path}`, init);
  console.log(name, r.status, await r.text());
};
await check("mcp", { method: "POST", headers: { authorization: "Bearer TOKEN", "content-type": "application/json" }, body: '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' });
await check("upload 5MB", { method: "PUT", body: new Uint8Array(5 * 1024 * 1024) }, "/api/upload?name=a.zip");
const wrong = new WebSocket(wsURL, { headers: { authorization: "Bearer nope" } } as any);
await new Promise((ok) => { wrong.onerror = ok; wrong.onclose = ok; });
console.log("wrong secret rejected");
ws.close();
await new Promise((r) => setTimeout(r, 500));
await check("offline", { method: "POST", body: "{}" });
process.exit(0);
