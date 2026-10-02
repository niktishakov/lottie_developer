// Сборка сцены из нескольких файлов — порт LottieMerge.swift. Часть вставляется группой (null-слой с именем файла).
import type { Lottie } from "./types.ts";

export function size(lottie: Lottie): { width: number; height: number } | null {
  return typeof lottie.w === "number" && typeof lottie.h === "number" ? { width: lottie.w, height: lottie.h } : null;
}

export function add(part: Lottie, base: Lottie, group: string, origin = { x: 0, y: 0 }): { lottie: Lottie; group: string } {
  if (!Array.isArray(part.layers)) throw new Error("Not a valid Lottie composition");
  const root = structuredClone(base);
  const src = structuredClone(part);
  const layers: any[] = root.layers ?? [];
  const assets: any[] = root.assets ?? [];
  const op = typeof root.op === "number" ? root.op : 120;

  const used = new Set(layers.map((l) => l.nm).filter((n) => typeof n === "string"));
  const unique = (n: string) => { let name = n, i = 2; while (used.has(name)) name = `${n} ${i++}`; used.add(name); return name; };
  const groupName = unique(group);

  const tag = `m${assets.length + layers.length + 1}_`;
  const idMap: Record<string, string> = {};
  for (const a of src.assets ?? []) { if (typeof a.id !== "string") continue; idMap[a.id] = tag + a.id; a.id = tag + a.id; assets.push(a); }

  let next = Math.max(0, ...layers.map((l) => (typeof l.ind === "number" ? l.ind : 0))) + 1;
  const groupInd = next++;
  const indMap: Record<number, number> = {};
  for (const l of src.layers) if (typeof l.ind === "number") indMap[l.ind] = next++;

  const inserted = src.layers.map((l: any) => {
    l.ind = typeof l.ind === "number" ? indMap[l.ind] : next++;
    l.parent = typeof l.parent === "number" && indMap[l.parent] != null ? indMap[l.parent] : groupInd;
    if (typeof l.refId === "string" && idMap[l.refId]) l.refId = idMap[l.refId];
    l.nm = unique(typeof l.nm === "string" ? l.nm : "layer");
    if (typeof l.op === "number" && l.op < op) l.op = op;
    return l;
  });
  const groupLayer = {
    ddd: 0, ind: groupInd, ty: 3, nm: groupName, sr: 1, ao: 0, ip: 0, op, st: 0, bm: 0,
    ks: { o: { a: 0, k: 100, ix: 11 }, r: { a: 0, k: 0, ix: 10 }, p: { a: 0, k: [origin.x, origin.y, 0], ix: 2 },
          a: { a: 0, k: [0, 0, 0], ix: 1 }, s: { a: 0, k: [100, 100, 100], ix: 6 } },
  };
  root.layers = [groupLayer, ...inserted, ...layers];
  root.assets = assets;
  return { lottie: root, group: groupName };
}

function layerIndex(lottie: Lottie, name: string): number {
  const i = (lottie.layers ?? []).findIndex((l: any) => l.nm === name);
  if (i < 0) throw new Error(`Layer not found: ${name}`);
  return i;
}

/** Позиция — левый верх содержимого (для групп) или сдвиг якоря; scale в %. */
export function move(name: string, lottie: Lottie, origin: { x: number; y: number } | null, scale: number | null): Lottie {
  const out = structuredClone(lottie);
  const l = out.layers[layerIndex(out, name)];
  const ks = (l.ks ??= {});
  if (origin) {
    const a: number[] = Array.isArray(ks.a?.k) ? ks.a.k : [0, 0, 0];
    ks.p = { a: 0, k: l.ty === 3 ? [origin.x, origin.y, 0] : [origin.x + a[0], origin.y + (a[1] ?? 0), 0], ix: 2 };
  }
  if (scale != null) ks.s = { a: 0, k: [scale, scale, 100], ix: 6 };
  return out;
}

export function reorder(name: string, lottie: Lottie, position: number): Lottie {
  const out = structuredClone(lottie);
  const [l] = out.layers.splice(layerIndex(out, name), 1);
  out.layers.splice(Math.max(0, Math.min(position, out.layers.length)), 0, l);
  return out;
}

export function rename(name: string, newName: string, lottie: Lottie): Lottie {
  const out = structuredClone(lottie);
  const i = layerIndex(out, name);
  if (out.layers.some((l: any) => l.nm === newName)) throw new Error(`Layer name already used: ${newName}`);
  out.layers[i].nm = newName;
  return out;
}
