// Кадры между посредником и айфоном (WebSocket, JSON-текст). Описание: docs/relay-protocol.md.
// Тело — base64, кусками по CHUNK байт: первый кадр req/res, следующие req-body/res-body, у последнего more=false.

export const CHUNK = 1024 * 1024;
export const MAX_BODY = 100 * 1024 * 1024;

export type ReqHead = { t: "req"; id: string; method: string; path: string; query: string; headers: Record<string, string>; body: string; more: boolean };
export type ResHead = { t: "res"; id: string; status: number; headers: Record<string, string>; body: string; more: boolean };
export type BodyPart = { t: "req-body" | "res-body"; id: string; body: string; more: boolean };
export type Frame = ReqHead | ResHead | BodyPart;

export function toB64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function fromB64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Запрос → кадры для айфона.
export function requestFrames(id: string, method: string, path: string, query: string, headers: Record<string, string>, body: Uint8Array): string[] {
  const parts = split(body);
  return parts.map((p, i) => JSON.stringify(i === 0
    ? { t: "req", id, method, path, query, headers, body: toB64(p), more: i < parts.length - 1 }
    : { t: "req-body", id, body: toB64(p), more: i < parts.length - 1 }));
}

export function split(body: Uint8Array): Uint8Array[] {
  if (body.length <= CHUNK) return [body];
  const parts: Uint8Array[] = [];
  for (let i = 0; i < body.length; i += CHUNK) parts.push(body.subarray(i, i + CHUNK));
  return parts;
}

/// Собирает ответ айфона из кадров res + res-body.
export class ResponseAssembler {
  status = 0;
  headers: Record<string, string> = {};
  private parts: Uint8Array[] = [];
  private size = 0;
  done = false;

  /// false — тело больше MAX_BODY.
  add(f: ResHead | BodyPart): boolean {
    if (f.t === "res") { this.status = f.status; this.headers = f.headers ?? {}; }
    const p = fromB64(f.body ?? "");
    this.size += p.length;
    if (this.size > MAX_BODY) return false;
    this.parts.push(p);
    this.done = !f.more;
    return true;
  }

  body(): Uint8Array<ArrayBuffer> {
    const out = new Uint8Array(this.size);
    let o = 0;
    for (const p of this.parts) { out.set(p, o); o += p.length; }
    return out;
  }
}
