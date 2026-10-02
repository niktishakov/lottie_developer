// Хаб устройств: iPhone с приложением Lottie Companion подключается по Wi-Fi (WebSocket) и
// — показывает то же, что просмотрщик, в настоящем lottie-ios;
// — рисует кадры для Claude (render_frame engine: "ios" / "ios-main-thread");
// — отчитывается, какой движок lottie-ios выбрал и почему.
import { networkInterfaces } from "node:os";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import type { ServerWebSocket } from "bun";

export interface DeviceInfo { name: string; model?: string; system?: string; lottie?: string; connectedAt: string }
export interface DeviceFrame { frame: number; png: string; width: number; height: number }
export interface DeviceRender { frames: DeviceFrame[]; engineRequested: string; engineUsed: string; lottieVersion?: string; warnings: string[]; device: string }

type Sock = ServerWebSocket<{ info?: DeviceInfo }>;

export class DeviceHub {
  readonly token: string;
  private socks = new Set<Sock>();
  private pending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void; timer: Timer }>();

  constructor(base: string) {
    // Токен постоянный (переживает перезапуск exe): iPhone переподключается сам.
    const f = join(base, "device_token");
    if (existsSync(f)) this.token = readFileSync(f, "utf8").trim();
    else { this.token = crypto.randomUUID().replace(/-/g, "").slice(0, 20); writeFileSync(f, this.token); }
  }

  devices(): DeviceInfo[] { return [...this.socks].map((s) => s.data.info).filter(Boolean) as DeviceInfo[]; }

  /** Адреса этого ПК в локальной сети — для QR. */
  static lanAddresses(): string[] {
    const out: string[] = [];
    for (const [name, list] of Object.entries(networkInterfaces())) {
      for (const a of list ?? []) {
        if (a.family !== "IPv4" || a.internal) continue;
        if (/^(169\.254|172\.(1[6-9]|2\d|3[01])\.0\.)/.test(a.address) && !/wi-?fi|wlan|en0/i.test(name)) continue; // link-local / docker
        out.push(a.address);
      }
    }
    // Wi-Fi и типичные домашние сети — первыми
    return out.sort((a, b) => Number(!a.startsWith("192.168.")) - Number(!b.startsWith("192.168.")));
  }

  open(ws: Sock) { this.socks.add(ws); }
  close(ws: Sock) { this.socks.delete(ws); }

  message(ws: Sock, raw: string | Buffer) {
    let m: any;
    try { m = JSON.parse(String(raw)); } catch { return; }
    if (m.type === "hello") { ws.data.info = { name: m.name ?? "iPhone", model: m.model, system: m.system, lottie: m.lottie, connectedAt: new Date().toISOString() }; return; }
    const p = m.reqId && this.pending.get(m.reqId);
    if (!p) return;
    this.pending.delete(m.reqId);
    clearTimeout(p.timer);
    if (m.type === "error") p.reject(new Error(m.message ?? "device error")); else p.resolve(m);
  }

  /** Отправить всем подключённым (показ текущей версии). */
  broadcast(msg: any) { const s = JSON.stringify(msg); for (const ws of this.socks) ws.send(s); }

  request(msg: any, timeoutMs = 45000): Promise<any> {
    const ws = [...this.socks].find((s) => s.data.info) ?? [...this.socks][0];
    if (!ws) return Promise.reject(new Error("No iPhone connected. In the viewer press “Connect iPhone” and scan the QR code with the Lottie Companion app."));
    const reqId = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(reqId); reject(new Error("iPhone did not answer in time — keep Lottie Companion open and the screen unlocked.")); }, timeoutMs);
      this.pending.set(reqId, { resolve, reject, timer });
      ws.send(JSON.stringify({ ...msg, reqId }));
    });
  }
}
