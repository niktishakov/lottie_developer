// Импорт пачки ассетов (zip или папка) в одну композицию — порт AssetBundle.swift.
// Холст — по самому большому файлу; крупные снизу, мелкие сверху; SVG/Lottie — группой по центру;
// картинки ≤ 4 px — «образцы цвета»: растягиваются на холст, вниз, скрытыми.
import { unzipSync } from "fflate";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, basename, extname } from "node:path";
import type { Lottie } from "./types.ts";
import { svgToLottie } from "./svg.ts";
import { parseSVG } from "./svgDom.ts";
import * as merge from "./merge.ts";
import * as images from "./images.ts";
import { apply } from "./overrides.ts";

export interface BundleFile { name: string; data: Uint8Array }
export interface BundleReport { lottie: Lottie; canvas: { width: number; height: number }; parts: string[]; warnings: string[]; usage: Record<string, string[]>; files: BundleFile[] }

const IMAGE = new Set(["png", "jpg", "jpeg", "webp", "gif"]);

/** Файлы из zip или папки (без __MACOSX и скрытых). */
export function readBundle(path: string): BundleFile[] {
  const out: BundleFile[] = [];
  const keep = (rel: string) => !rel.includes("__MACOSX") && !basename(rel).startsWith(".");
  if (extname(path).toLowerCase() === ".zip") {
    const files = unzipSync(new Uint8Array(readFileSync(path)));
    for (const [rel, data] of Object.entries(files)) if (!rel.endsWith("/") && keep(rel)) out.push({ name: basename(rel), data });
  } else {
    const walk = (d: string) => {
      for (const e of readdirSync(d)) {
        const p = join(d, e);
        if (!keep(e)) continue;
        if (statSync(p).isDirectory()) walk(p); else out.push({ name: e, data: new Uint8Array(readFileSync(p)) });
      }
    };
    walk(path);
  }
  return out;
}

export function svgSize(text: string): { width: number; height: number } {
  const root = parseSVG(text);
  const vb = root?.attrs.viewBox?.split(/[\s,]+/).map(Number).filter((n) => !Number.isNaN(n));
  if (vb && vb.length === 4) return { width: vb[2], height: vb[3] };
  const num = (s?: string) => (s ? parseFloat(s.replace(/[^0-9.]/g, "")) : NaN);
  return { width: num(root?.attrs.width) || 512, height: num(root?.attrs.height) || 512 };
}

export async function loadBundle(files: BundleFile[], fps = 60, frames = 120): Promise<BundleReport> {
  const dec = new TextDecoder();
  const items: { f: BundleFile; kind: string; size: { width: number; height: number } }[] = [];
  const warnings: string[] = [];
  for (const f of files) {
    const ext = extname(f.name).slice(1).toLowerCase();
    if (ext === "svg") items.push({ f, kind: "svg", size: svgSize(dec.decode(f.data)) });
    else if (IMAGE.has(ext)) { const px = images.pixelSize(f.data); if (px) items.push({ f, kind: "image", size: px }); }
    else if (ext === "json") {
      try { const l = JSON.parse(dec.decode(f.data)); const s = merge.size(l); if (s && Array.isArray(l.layers)) items.push({ f, kind: "lottie", size: s }); }
      catch { warnings.push(`Skipped ${f.name} (not Lottie JSON)`); }
    } else warnings.push(`Skipped ${f.name} (unsupported type)`);
  }
  if (!items.length) throw new Error("No SVG, images or Lottie JSON found");
  const area = (i: (typeof items)[number]) => i.size.width * i.size.height;
  const canvas = items.reduce((a, b) => (area(b) > area(a) ? b : a)).size;
  let lottie = images.blank(Math.round(canvas.width), Math.round(canvas.height), fps, frames);
  const parts: string[] = [], swatches: string[] = [], usage: Record<string, string[]> = {};
  const keep = (file: string, part: string) => (usage[file] ??= []).push(part);

  for (const it of [...items].sort((a, b) => area(b) - area(a))) {
    const name = basename(it.f.name, extname(it.f.name));
    const origin = { x: (canvas.width - it.size.width) / 2, y: (canvas.height - it.size.height) / 2 };
    if (it.kind === "svg" || it.kind === "lottie") {
      let part: Lottie;
      if (it.kind === "svg") {
        const r = await svgToLottie(dec.decode(it.f.data));
        warnings.push(...r.warnings.map((w) => `${it.f.name}: ${w}`));
        part = r.lottie;
      } else part = JSON.parse(dec.decode(it.f.data));
      const r = merge.add(part, lottie, name, origin);
      lottie = r.lottie; parts.unshift(r.group); keep(it.f.name, r.group);
    } else if (it.size.width <= 4 && it.size.height <= 4) {
      const r = images.addImage(lottie, it.f.data, name, { x: 0, y: 0, width: canvas.width, height: canvas.height });
      lottie = apply({ [r.layerName]: { hidden: true } }, merge.reorder(r.layerName, r.lottie, Number.MAX_SAFE_INTEGER));
      swatches.push(r.layerName); parts.push(r.layerName); keep(it.f.name, r.layerName);
    } else {
      const r = images.addImage(lottie, it.f.data, name, null);
      lottie = r.lottie; parts.unshift(r.layerName); keep(it.f.name, r.layerName);
    }
  }
  if (swatches.length) warnings.push(`Tiny images treated as color swatches: ${swatches.join(", ")} — stretched to the canvas, at the bottom, hidden`);
  return { lottie, canvas, parts, warnings, usage, files: items.map((i) => i.f) };
}
