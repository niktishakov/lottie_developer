// Растровые ассеты как слои-картинки — порт LottieImageLayers.swift (addImage/place/imageFrames/blank).
// Базовые asset/layer-хелперы — в imageLayers.ts (общие с SVG-импортом).
import type { Lottie } from "./types.ts";
import { imageAsset, imageLayer } from "./imageLayers.ts";

export interface Rect { x: number; y: number; width: number; height: number }
export interface Px { width: number; height: number }

export function blank(width: number, height: number, fps = 60, frames = 120): Lottie {
  return { v: "5.7.4", fr: fps, ip: 0, op: frames, w: width, h: height, nm: "Composition", ddd: 0, assets: [], layers: [] };
}

/** Размер картинки по заголовку (PNG, JPEG, WebP, GIF) без декодирования. */
export function pixelSize(b: Uint8Array): Px | null {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50) return { width: dv.getUint32(16), height: dv.getUint32(20) };
  if (b.length > 10 && b[0] === 0x47 && b[1] === 0x49) return { width: dv.getUint16(6, true), height: dv.getUint16(8, true) };
  if (b.length > 30 && b[0] === 0x52 && b[8] === 0x57) {
    const chunk = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (chunk === "VP8X") return { width: 1 + (b[24] | (b[25] << 8) | (b[26] << 16)), height: 1 + (b[27] | (b[28] << 8) | (b[29] << 16)) };
    if (chunk === "VP8 ") return { width: dv.getUint16(26, true) & 0x3fff, height: dv.getUint16(28, true) & 0x3fff };
    if (chunk === "VP8L") { const v = dv.getUint32(21, true); return { width: (v & 0x3fff) + 1, height: ((v >> 14) & 0x3fff) + 1 }; }
  }
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { width: dv.getUint16(i + 7), height: dv.getUint16(i + 5) };
      i += 2 + dv.getUint16(i + 2);
    }
  }
  return null;
}

export function addImage(lottie: Lottie, image: Uint8Array, name: string, frame: Rect | null): { lottie: Lottie; layerName: string } {
  const px = pixelSize(image);
  if (!px) throw new Error(`Unsupported image (${name})`);
  const root = structuredClone(lottie);
  const layers: any[] = (root.layers ??= []);
  const assets: any[] = (root.assets ??= []);
  const compW = root.w ?? px.width, compH = root.h ?? px.height, op = root.op ?? 120;
  const existing = new Set(layers.map((l) => l.nm));
  let layerName = name || "image";
  if (existing.has(layerName)) { let i = 2; while (existing.has(`${layerName} ${i}`)) i++; layerName = `${layerName} ${i}`; }
  const ids = new Set(assets.map((a) => a.id));
  let n = assets.length + 1;
  while (ids.has(`image_${n}`)) n++;
  const id = `image_${n}`;
  assets.push(imageAsset(id, image, px));
  const rect = frame ?? defaultFrame(px, compW, compH);
  const maxInd = Math.max(0, ...layers.map((l) => (typeof l.ind === "number" ? l.ind : 0)));
  layers.unshift(imageLayer(layerName, id, px, rect, maxInd + 1, op));
  return { lottie: root, layerName };
}

export function place(name: string, lottie: Lottie, rect: Rect): Lottie {
  const root = structuredClone(lottie);
  const l = (root.layers ?? []).find((x: any) => x.nm === name);
  if (!l) throw new Error(`Layer not found: ${name}`);
  const a = l.ty === 2 ? (root.assets ?? []).find((x: any) => x.id === l.refId) : null;
  if (!a) throw new Error(`${name} is not an image layer`);
  l.ks = imageLayer(name, a.id, { width: a.w, height: a.h }, rect, l.ind, l.op).ks;
  return root;
}

export function imageFrames(lottie: Lottie): Record<string, Rect> {
  const out: Record<string, Rect> = {};
  for (const l of lottie.layers ?? []) {
    if (l.ty !== 2) continue;
    const a = (lottie.assets ?? []).find((x: any) => x.id === l.refId);
    if (!a || l.ks?.p?.a === 1 || l.ks?.s?.a === 1) continue;
    const p = l.ks?.p?.k ?? [a.w / 2, a.h / 2], s = l.ks?.s?.k ?? [100, 100];
    const rw = (a.w * s[0]) / 100, rh = (a.h * (s[1] ?? s[0])) / 100;
    out[l.nm] = { x: p[0] - rw / 2, y: p[1] - rh / 2, width: rw, height: rh };
  }
  return out;
}

function defaultFrame(px: Px, compW: number, compH: number): Rect {
  const k = Math.min(1, compW / px.width, compH / px.height);
  const w = px.width * k, h = px.height * k;
  return { x: (compW - w) / 2, y: (compH - h) / 2, width: w, height: h };
}
