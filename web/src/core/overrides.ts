// Правки слоёв поверх Lottie (цвет, множитель прозрачности, скрытие) — порт LottieOverrides.swift.
import type { Lottie } from "./types.ts";

export interface LayerOverride { color?: string | null; opacity?: number | null; hidden?: boolean }
export interface LayerInfo { index: number; name: string; type: number; isMatte: boolean }

const isEmpty = (o: LayerOverride) => !o.color && o.opacity == null && !o.hidden;
const clone = <T>(x: T): T => structuredClone(x);

export function layers(lottie: Lottie): LayerInfo[] {
  return (lottie.layers ?? []).map((l: any, i: number) => ({
    index: i, name: typeof l.nm === "string" ? l.nm : `Layer ${i + 1}`,
    type: typeof l.ty === "number" ? l.ty : 4, isMatte: l.td === 1,
  }));
}

export function rgb(hex?: string | null): number[] | null {
  let s = (hex ?? "").trim();
  if (!s) return null;
  if (s.startsWith("#")) s = s.slice(1);
  if (s.length === 3) s = s.split("").map((c) => c + c).join("");
  if (s.length !== 6 || !/^[0-9a-f]{6}$/i.test(s)) return null;
  const v = parseInt(s, 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

export function apply(overrides: Record<string, LayerOverride>, lottie: Lottie): Lottie {
  const active = Object.entries(overrides).filter(([, o]) => !isEmpty(o));
  if (!active.length || !Array.isArray(lottie.layers)) return lottie;
  const map = Object.fromEntries(active);
  const out = clone(lottie);
  for (const l of out.layers) {
    const o = map[l.nm];
    if (!o) continue;
    if (o.hidden) l.hd = true;
    const c = rgb(o.color);
    if (c && Array.isArray(l.shapes)) recolor(l.shapes, c);
    if (o.opacity != null && l.ks) l.ks.o = scaleOpacity(l.ks.o, Math.max(0, Math.min(o.opacity, 100)) / 100);
  }
  return out;
}

/** Видим только один слой (+ его матте и null-родители) — для выбора кликом и рамки. */
export function isolate(layerIndex: number, lottie: Lottie): Lottie {
  const out = clone(lottie);
  out.layers?.forEach((l: any, i: number) => {
    if (i === layerIndex || l.ty === 3 || (i === layerIndex - 1 && l.td === 1)) return;
    l.hd = true;
  });
  return out;
}

export function firstColor(layerName: string, lottie: Lottie): string | null {
  const layer = (lottie.layers ?? []).find((l: any) => l.nm === layerName);
  const find = (items: any[]): number[] | null => {
    for (const it of items ?? []) {
      if ((it.ty === "fl" || it.ty === "st") && Array.isArray(it.c?.k) && it.c.k.length >= 3) return it.c.k.slice(0, 3);
      if (Array.isArray(it.it)) { const c = find(it.it); if (c) return c; }
    }
    return null;
  };
  const c = layer ? find(layer.shapes) : null;
  if (!c) return null;
  return "#" + c.map((v) => Math.floor(v * 255).toString(16).padStart(2, "0").toUpperCase()).join("");
}

function recolor(items: any[], c: number[]) {
  for (const it of items) {
    if (it.ty === "fl" || it.ty === "st") it.c = { a: 0, k: [...c, 1] };
    if (Array.isArray(it.it)) recolor(it.it, c);
  }
}

function scaleOpacity(o: any, f: number): any {
  if (!o || typeof o !== "object") return { a: 0, k: 100 * f };
  if (o.a === 1 && Array.isArray(o.k)) {
    for (const kf of o.k) for (const key of ["s", "e"]) if (Array.isArray(kf[key])) kf[key] = kf[key].map((v: number) => v * f);
  } else if (typeof o.k === "number") o.k = o.k * f;
  else if (Array.isArray(o.k) && typeof o.k[0] === "number") o.k = o.k[0] * f;
  return o;
}
