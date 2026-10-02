// SVG → статичный Lottie с ИМЕНОВАННЫМИ слоями — порт Sources/macOS/SVGToLottie.swift (+ SVGPath).
// Каждый рисуемый элемент → слой `ty:4` с `nm` = svg `id` (или сгенерированное имя), якорь в центре bbox.
// Элементы с blur/mask/вытянутым radial gradient → картинка (resvg ×3, обрезка по альфе) слоем `ty:2`.
import { initWasm, Resvg } from "@resvg/resvg-wasm";
// @ts-ignore — Bun: импорт файла как пути (работает и внутри `bun build --compile`).
import wasmPath from "@resvg/resvg-wasm/index_bg.wasm" with { type: "file" };
import { encode as encodePNG } from "fast-png";
import type { SVGImportResult } from "./types.ts";
import { parseSVG, rasterNodes as findRasterNodes, isolate, nonRendered, type SVGNode } from "./svgDom.ts";
import { imageAsset, imageLayer, type ImageRect } from "./imageLayers.ts";

type Attrs = Record<string, string>;
type Obj = Record<string, any>;

// MARK: - Swift-совместимые примитивы

/** Swift `Double(String)`: вся строка — десятичное число, без пробелов. */
function dbl(s: string): number | null {
  return /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s) ? Number(s) : null;
}

/** Swift `.trimmingCharacters(in: .whitespaces)` — пробелы и табы, без переводов строк. */
function trimWS(s: string): string {
  return s.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");
}

function num(s: string | undefined): number | null {
  if (s === undefined) return null;
  return dbl([...trimWS(s)].filter((c) => "0123456789.eE+-".includes(c)).join(""));
}

function styleValue(style: string | undefined, key: string): string | undefined {
  if (style === undefined) return undefined;
  for (const pair of style.split(";").filter((p) => p !== "")) {
    const at = pair.indexOf(":");
    // Swift split(maxSplits: 1) отбрасывает пустые куски.
    const kv = at < 0 ? [pair] : [pair.slice(0, at), pair.slice(at + 1)].filter((p) => p !== "");
    if (kv.length === 2 && trimWS(kv[0]) === key) return trimWS(kv[1]);
  }
  return undefined;
}

function styleNum(style: string | undefined, key: string): number | null {
  const v = styleValue(style, key);
  return v === undefined ? null : num(v);
}

function hexColor(hex: string): number[] {
  let h = hex.replaceAll("#", "");
  if ([...h].length === 3) h = [...h].map((c) => c + c).join("");
  if ([...h].length !== 6 || !/^[+-]?[0-9a-fA-F]+$/.test(h)) return [0, 0, 0, 1];
  const v = parseInt(h, 16);
  return [((v >> 16) & 0xff) / 255, ((v >> 8) & 0xff) / 255, (v & 0xff) / 255, 1];
}

function rgbColor(s: string): number[] {
  const nums = s.split(/[^0-9.]+/).filter((p) => p !== "").map(dbl).filter((v): v is number => v !== null);
  if (nums.length < 3) return [0, 0, 0, 1];
  return [nums[0] / 255, nums[1] / 255, nums[2] / 255, nums.length >= 4 ? nums[3] : 1];
}

/** → [r,g,b,a] 0..1, или null если none/отсутствует. */
function color(attr: string | undefined, style: string | undefined, key: string): number[] | null {
  const v = attr ?? styleValue(style, key);
  if (v === undefined) return null;
  const raw = trimWS(v).toLowerCase();
  if (raw === "none" || raw === "") return null;
  if (raw.startsWith("#")) return hexColor(raw);
  switch (raw) {
    case "black": return [0, 0, 0, 1];
    case "white": return [1, 1, 1, 1];
    case "red": return [1, 0, 0, 1];
    case "green": return [0, 0.5, 0, 1];
    case "blue": return [0, 0, 1, 1];
    case "gray": case "grey": return [0.5, 0.5, 0.5, 1];
    case "yellow": return [1, 1, 0, 1];
    case "orange": return [1, 0.65, 0, 1];
    default:
      if (raw.startsWith("rgb")) return rgbColor(raw);
      return [0, 0, 0, 1]; // неизвестный цвет → чёрный
  }
}

function points(s: string | undefined): number[][] {
  if (s === undefined) return [];
  const nums = s.split(/[ ,\n]/).filter((p) => p !== "").map(dbl).filter((v): v is number => v !== null);
  const pts: number[][] = [];
  for (let i = 0; i + 1 < nums.length; i += 2) pts.push([nums[i], nums[i + 1]]);
  return pts;
}

function gradientRef(v: string | undefined): string | null {
  if (v === undefined) return null;
  const r = v.indexOf("url(#");
  if (r < 0) return null;
  const rest = v.slice(r + 5);
  const end = rest.indexOf(")");
  return end < 0 ? null : rest.slice(0, end);
}

// MARK: - Affine (CGAffineTransform: x' = a x + c y + tx, y' = b x + d y + ty)

type Affine = [number, number, number, number, number, number];
const IDENTITY: Affine = [1, 0, 0, 1, 0, 0];

/** CG `t1.concatenating(t2)`: сначала t1, потом t2. */
function concat(t1: Affine, t2: Affine): Affine {
  return [
    t1[0] * t2[0] + t1[1] * t2[2],
    t1[0] * t2[1] + t1[1] * t2[3],
    t1[2] * t2[0] + t1[3] * t2[2],
    t1[2] * t2[1] + t1[3] * t2[3],
    t1[4] * t2[0] + t1[5] * t2[2] + t2[4],
    t1[4] * t2[1] + t1[5] * t2[3] + t2[5],
  ];
}

function apply(t: Affine, x: number, y: number): [number, number] {
  return [t[0] * x + t[2] * y + t[4], t[1] * x + t[3] * y + t[5]];
}

/** SVG transform-лист → аффинная матрица (matrix, translate, scale, rotate). */
export function parseTransform(s: string | undefined): Affine {
  if (s === undefined) return IDENTITY;
  let total = IDENTITY;
  const re = /(matrix|translate|scale|rotate)\s*\(([^)]*)\)/g;
  for (let m; (m = re.exec(s)); ) {
    const args = m[2].split(/[ ,]/).filter((p) => p !== "").map(dbl).filter((v): v is number => v !== null);
    let t: Affine = IDENTITY;
    switch (m[1]) {
      case "matrix":
        if (args.length === 6) t = [args[0], args[1], args[2], args[3], args[4], args[5]];
        break;
      case "translate": t = [1, 0, 0, 1, args[0] ?? 0, args.length > 1 ? args[1] : 0]; break;
      case "scale": t = [args[0] ?? 1, 0, 0, args.length > 1 ? args[1] : (args[0] ?? 1), 0, 0]; break;
      case "rotate": {
        const a = ((args[0] ?? 0) * Math.PI) / 180;
        const r: Affine = [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0];
        if (args.length === 3) {
          const tr: Affine = [1, 0, 0, 1, args[1], args[2]];
          const back: Affine = [1, 0, 0, 1, -args[1], -args[2]];
          t = concat(back, concat(r, tr));
        } else t = r;
        break;
      }
    }
    total = concat(t, total);
  }
  return total;
}

// MARK: - Path parser (SVGPath)

interface Subpath { v: number[][]; i: number[][]; o: number[][]; closed: boolean }

const isLetter = (c: string) => /\p{L}/u.test(c);
const isDigit = (c: string) => /\p{N}/u.test(c);

function tokenize(d: string): string[] {
  const tokens: string[] = [];
  const cs = [...d];
  let i = 0;
  const isNumStart = (c: string) => isDigit(c) || c === "." || c === "-" || c === "+";
  while (i < cs.length) {
    const c = cs[i];
    if (isLetter(c)) { tokens.push(c); i++; continue; }
    if (c === " " || c === "," || c === "\n" || c === "\t") { i++; continue; }
    if (isNumStart(c)) {
      let s = "";
      if (c === "-" || c === "+") { s += c; i++; }
      let seenDot = false, seenE = false;
      while (i < cs.length) {
        const ch = cs[i];
        if (isDigit(ch)) { s += ch; i++; }
        else if (ch === "." && !seenDot) { seenDot = true; s += ch; i++; }
        else if ((ch === "e" || ch === "E") && !seenE) {
          seenE = true; s += ch; i++;
          if (i < cs.length && (cs[i] === "-" || cs[i] === "+")) { s += cs[i]; i++; }
        } else break;
      }
      if (s !== "") tokens.push(s);
      continue;
    }
    i++;
  }
  return tokens;
}

export function parsePath(d: string): { subpaths: Subpath[]; approximated: boolean } {
  const tokens = tokenize(d);
  const subpaths: Subpath[] = [];
  let cur: Subpath | null = null;
  let x = 0, y = 0, idx = 0;
  let lastCmd = " ", prevUpper = " ";
  let prevCtrlX = 0, prevCtrlY = 0, prevQuadX = 0, prevQuadY = 0;
  let approximated = false;

  const num = () => { if (idx >= tokens.length) return 0; const v = dbl(tokens[idx]) ?? 0; idx++; return v; };
  const newSub = (px: number, py: number) => {
    if (cur) subpaths.push(cur);
    cur = { v: [[px, py]], i: [[0, 0]], o: [[0, 0]], closed: false };
  };
  const addCurve = (c1x: number, c1y: number, c2x: number, c2y: number, ex: number, ey: number) => {
    if (!cur) return;
    cur.o[cur.o.length - 1] = [c1x - x, c1y - y];
    x = ex; y = ey;
    cur.v.push([x, y]); cur.i.push([c2x - x, c2y - y]); cur.o.push([0, 0]);
    prevCtrlX = c2x; prevCtrlY = c2y;
  };
  const addQuad = (qx: number, qy: number, ex: number, ey: number) => {
    const c1x = x + (2 / 3) * (qx - x), c1y = y + (2 / 3) * (qy - y);
    const c2x = ex + (2 / 3) * (qx - ex), c2y = ey + (2 / 3) * (qy - ey);
    prevQuadX = qx; prevQuadY = qy;
    addCurve(c1x, c1y, c2x, c2y, ex, ey);
  };
  const addLine = (ex: number, ey: number) => {
    if (!cur) return;
    cur.o[cur.o.length - 1] = [0, 0];
    x = ex; y = ey;
    cur.v.push([x, y]); cur.i.push([0, 0]); cur.o.push([0, 0]);
  };

  while (idx < tokens.length) {
    const tok = tokens[idx];
    const cmdChar = [...tok][0] ?? " ";
    const isCmd = "MmLlHhVvCcSsQqTtAaZz".includes(cmdChar) && dbl(tok) === null;
    let cmd: string;
    if (isCmd) { cmd = cmdChar; idx++; } else cmd = lastCmd === " " ? "L" : lastCmd;
    // В Swift неявный повтор после Z зацикливался (Z не съедает токен) — здесь съедаем лишнее число.
    if (!isCmd && (cmd === "Z" || cmd === "z")) { idx++; continue; }
    lastCmd = cmd;
    const rel = cmd !== cmd.toUpperCase() && cmd === cmd.toLowerCase();
    const upper = cmd.toUpperCase();
    const ox = () => (rel ? x : 0), oy = () => (rel ? y : 0);

    switch (upper) {
      case "M": {
        const px = num() + ox(), py = num() + oy();
        x = px; y = py; newSub(px, py); lastCmd = rel ? "l" : "L";
        break;
      }
      case "L": { const ex = num() + ox(); const ey = num() + oy(); addLine(ex, ey); break; }
      case "H": addLine(num() + ox(), y); break;
      case "V": addLine(x, num() + oy()); break;
      case "C": {
        const c1x = num() + ox(), c1y = num() + oy();
        const c2x = num() + ox(), c2y = num() + oy();
        const ex = num() + ox(), ey = num() + oy();
        addCurve(c1x, c1y, c2x, c2y, ex, ey);
        break;
      }
      case "S": {
        const reflect = prevUpper === "C" || prevUpper === "S";
        const c1x = reflect ? 2 * x - prevCtrlX : x, c1y = reflect ? 2 * y - prevCtrlY : y;
        const c2x = num() + ox(), c2y = num() + oy();
        const ex = num() + ox(), ey = num() + oy();
        addCurve(c1x, c1y, c2x, c2y, ex, ey);
        break;
      }
      case "Q": {
        const qx = num() + ox(), qy = num() + oy();
        const ex = num() + ox(), ey = num() + oy();
        addQuad(qx, qy, ex, ey);
        break;
      }
      case "T": {
        const reflect = prevUpper === "Q" || prevUpper === "T";
        const qx = reflect ? 2 * x - prevQuadX : x, qy = reflect ? 2 * y - prevQuadY : y;
        const ex = num() + ox(), ey = num() + oy();
        addQuad(qx, qy, ex, ey);
        break;
      }
      case "A": {
        // rx ry x-rot large-arc sweep x y — дугу не строим, аппроксимируем отрезком до конца.
        num(); num(); num(); num(); num();
        const ex = num() + ox(), ey = num() + oy();
        addLine(ex, ey); approximated = true;
        break;
      }
      case "Z":
        if (cur) (cur as Subpath).closed = true;
        break;
      default:
        idx++; // неизвестная команда — съедаем токен
    }
    prevUpper = upper;
  }
  if (cur) subpaths.push(cur);
  return { subpaths: subpaths.filter((s) => s.v.length >= 2), approximated };
}

// MARK: - Gradients

interface Gradient { radial: boolean; attrs: Attrs; stops: { offset: number; color: number[] }[] }

function collectGradients(root: SVGNode): Map<string, Gradient> {
  const raw = new Map<string, SVGNode>();
  const walk = (n: SVGNode) => {
    const t = n.tag.toLowerCase();
    if ((t === "lineargradient" || t === "radialgradient") && n.attrs["id"] !== undefined) raw.set(n.attrs["id"], n);
    n.children.forEach(walk);
  };
  walk(root);
  const out = new Map<string, Gradient>();
  for (const [id, n] of raw) {
    const attrs: Attrs = { ...n.attrs };
    let stopsNode = n;
    let hops = 0;
    // xlink:href / href — наследование стопов и атрибутов
    while (stopsNode.children.length === 0 && hops < 5) {
      const href = (stopsNode.attrs["xlink:href"] ?? stopsNode.attrs["href"])?.replaceAll("#", "");
      const parent = href === undefined ? undefined : raw.get(href);
      if (!parent) break;
      for (const [k, v] of Object.entries(parent.attrs)) if (attrs[k] === undefined) attrs[k] = v;
      stopsNode = parent; hops++;
    }
    const stops = stopsNode.children.filter((c) => c.tag.toLowerCase() === "stop").map((st) => {
      const offRaw = st.attrs["offset"] ?? styleValue(st.attrs["style"], "offset") ?? "0";
      let off = num(offRaw) ?? 0;
      if (offRaw.includes("%")) off /= 100;
      const c = color(st.attrs["stop-color"], st.attrs["style"], "stop-color") ?? [0, 0, 0, 1];
      c[3] *= num(st.attrs["stop-opacity"]) ?? styleNum(st.attrs["style"], "stop-opacity") ?? 1;
      return { offset: Math.min(Math.max(off, 0), 1), color: c };
    });
    if (stops.length === 0) continue;
    out.set(id, { radial: n.tag.toLowerCase() === "radialgradient", attrs, stops });
  }
  return out;
}

function radialAnisotropy(g: Gradient): number {
  const t = parseTransform(g.attrs["gradientTransform"]);
  const a = apply(t, 1, 0), b = apply(t, 0, 1), o = apply(t, 0, 0);
  const rx = Math.hypot(a[0] - o[0], a[1] - o[1]), ry = Math.hypot(b[0] - o[0], b[1] - o[1]);
  return Math.max(rx, ry) / Math.max(Math.min(rx, ry), 0.0001);
}

/** blur / маска / вытянутый radial gradient (Lottie рисует только круглые) → картинка. */
function needsRasterization(attrs: Attrs, gradients: Map<string, Gradient>): boolean {
  for (const key of ["filter", "mask"]) {
    const v = attrs[key] ?? styleValue(attrs["style"], key);
    if (v !== undefined && v !== "none" && v !== "") return true;
  }
  for (const key of ["fill", "stroke"]) {
    const id = gradientRef(attrs[key] ?? styleValue(attrs["style"], key));
    const g = id === null ? undefined : gradients.get(id);
    if (g && g.radial && radialAnisotropy(g) > 1.5) return true;
  }
  return false;
}

interface BBox { minX: number; minY: number; maxX: number; maxY: number }

function bboxOf(verts: number[][]): BBox | null {
  const first = verts[0];
  if (!first || first.length < 2) return null;
  const b = { minX: first[0], minY: first[1], maxX: first[0], maxY: first[1] };
  for (const v of verts) {
    if (v.length < 2) continue;
    b.minX = Math.min(b.minX, v[0]); b.minY = Math.min(b.minY, v[1]);
    b.maxX = Math.max(b.maxX, v[0]); b.maxY = Math.max(b.maxY, v[1]);
  }
  return b;
}

function gradientItem(g: Gradient, bbox: BBox, opacity: number, strokeWidth: number | null): Obj {
  const objectBox = (g.attrs["gradientUnits"] ?? "objectBoundingBox") !== "userSpaceOnUse";
  const t = parseTransform(g.attrs["gradientTransform"]);
  const coord = (key: string, def: number) => {
    const raw = g.attrs[key];
    if (raw === undefined) return def;
    let v = num(raw);
    if (v === null) return def;
    if (raw.includes("%")) v /= 100;
    return v;
  };
  const map = (px: number, py: number): number[] => {
    const q = apply(t, px, py);
    if (objectBox) {
      const w = bbox.maxX - bbox.minX, h = bbox.maxY - bbox.minY;
      return [bbox.minX + q[0] * w, bbox.minY + q[1] * h];
    }
    return [q[0], q[1]];
  };
  let start: number[], end: number[];
  if (g.radial) {
    const cx = coord("cx", 0.5), cy = coord("cy", 0.5), r = coord("r", 0.5);
    start = map(cx, cy); end = map(cx + r, cy);
  } else {
    start = map(coord("x1", 0), coord("y1", 0));
    end = map(coord("x2", 1), coord("y2", 0));
  }
  const stops = [...g.stops].sort((a, b) => a.offset - b.offset);
  const k: number[] = [];
  for (const st of stops) k.push(st.offset, st.color[0], st.color[1], st.color[2]);
  for (const st of stops) k.push(st.offset, st.color[3]);
  const item: Obj = {
    ty: strokeWidth === null ? "gf" : "gs", o: kScalar(opacity * 100), bm: 0, r: 1,
    g: { p: stops.length, k: { a: 0, k } },
    s: kStatic(start), e: kStatic(end), t: g.radial ? 2 : 1,
    nm: "Gradient", hd: false,
  };
  if (g.radial) { item.h = kScalar(0); item.a = kScalar(0); }
  if (strokeWidth !== null) { item.w = kScalar(strokeWidth); item.lc = 2; item.lj = 2; item.ml = 4; }
  return item;
}

// MARK: - Lottie shape helpers

function kStatic(v: number[], ix?: number): Obj { const d: Obj = { a: 0, k: v }; if (ix !== undefined) d.ix = ix; return d; }
function kScalar(v: number, ix?: number): Obj { const d: Obj = { a: 0, k: v }; if (ix !== undefined) d.ix = ix; return d; }

function shFromVertices(verts: number[][], closed: boolean): Obj {
  const zeros = verts.map(() => [0, 0]);
  return { ty: "sh", ix: 1, nm: "Path", ks: { a: 0, k: { i: zeros, o: zeros.map((z) => [...z]), v: verts, c: closed } },
    mn: "ADBE Vector Shape - Group", hd: false };
}

function shFromBezier(sp: Subpath): Obj {
  return { ty: "sh", ix: 1, nm: "Path", ks: { a: 0, k: { i: sp.i, o: sp.o, v: sp.v, c: sp.closed } },
    mn: "ADBE Vector Shape - Group", hd: false };
}

function fillItem(c: number[]): Obj {
  return { ty: "fl", c: kStatic([c[0], c[1], c[2]]), o: kScalar(c[3] * 100), r: 1, bm: 0,
    nm: "Fill", mn: "ADBE Vector Graphic - Fill", hd: false };
}

function strokeItem(c: number[], width: number): Obj {
  return { ty: "st", c: kStatic([c[0], c[1], c[2]]), o: kScalar(c[3] * 100), w: kScalar(width), lc: 2, lj: 2, ml: 4, bm: 0,
    nm: "Stroke", mn: "ADBE Vector Graphic - Stroke", hd: false };
}

function groupTransform(): Obj {
  return { ty: "tr", p: kStatic([0, 0]), a: kStatic([0, 0]), s: kStatic([100, 100]),
    r: kScalar(0), o: kScalar(100), sk: kScalar(0), sa: kScalar(0), nm: "Transform" };
}

// MARK: - Collector (обход документа как XMLParserDelegate в Swift)

interface Element { tag: string; attrs: Attrs; name: string }

const DRAWABLE = new Set(["rect", "circle", "ellipse", "line", "polygon", "polyline", "path"]);

class Collector {
  elements: Element[] = [];
  warnings: string[] = [];
  private svgAttrs: Attrs = {};
  private groupIdStack: string[] = [];
  private counter = 0;
  private rasterDepth = 0;
  private rasterCount = 0;
  private skipDepth = 0;
  private sawUnsupportedTransform = false;

  constructor(private needsRaster: (a: Attrs) => boolean) {}

  size(): [number, number] {
    const vbRaw = this.svgAttrs["viewBox"];
    if (vbRaw !== undefined) {
      const vb = vbRaw.split(/[ ,]/).filter((p) => p !== "").map(dbl).filter((v): v is number => v !== null);
      if (vb.length === 4) return [vb[2], vb[3]];
    }
    const dim = (s: string | undefined) => (s === undefined ? null : dbl([...s].filter((c) => "0123456789.".includes(c)).join("")));
    return [dim(this.svgAttrs["width"]) ?? 512, dim(this.svgAttrs["height"]) ?? 512];
  }

  walk(n: SVGNode) {
    this.start(n.tag, n.attrs);
    n.children.forEach((c) => this.walk(c));
    this.end(n.tag);
  }

  finish() {
    if (this.sawUnsupportedTransform) this.warnings.push("Some elements use SVG transforms (not applied) — geometry may differ");
  }

  private start(name: string, attrs: Attrs) {
    const tag = name.toLowerCase();
    if (tag === "svg") this.svgAttrs = attrs;
    if (nonRendered.has(tag)) { this.skipDepth++; return; }
    if (this.skipDepth > 0) return;
    if (this.rasterDepth > 0) { this.rasterDepth++; return; }
    if (tag !== "svg" && this.needsRaster(attrs)) {
      this.counter++;
      const nm = this.layerName(attrs["id"], tag === "g" ? "group" : tag, this.counter);
      this.elements.push({ tag: "__raster", attrs: { index: String(this.rasterCount) }, name: nm });
      this.rasterCount++;
      this.rasterDepth = 1;
      return;
    }
    if (tag === "g") {
      this.groupIdStack.push(attrs["id"] ?? "");
      if (attrs["transform"] !== undefined) this.sawUnsupportedTransform = true;
      return;
    }
    if (!DRAWABLE.has(tag)) return;
    if (attrs["transform"] !== undefined) this.sawUnsupportedTransform = true;
    this.counter++;
    this.elements.push({ tag, attrs, name: this.layerName(attrs["id"], tag, this.counter) });
  }

  private end(name: string) {
    const tag = name.toLowerCase();
    if (nonRendered.has(tag)) { this.skipDepth = Math.max(0, this.skipDepth - 1); return; }
    if (this.skipDepth > 0) return;
    if (this.rasterDepth > 0) { this.rasterDepth--; return; }
    if (tag === "g" && this.groupIdStack.length > 0) this.groupIdStack.pop();
  }

  private layerName(id: string | undefined, tag: string, ordinal: number): string {
    if (id !== undefined && id !== "") return id;
    const group = [...this.groupIdStack].reverse().find((g) => g !== "");
    if (group !== undefined) return `${group}-${tag}-${ordinal}`;
    return `${tag}-${ordinal}`;
  }
}

// MARK: - Raster fallback (resvg)

let wasmReady: Promise<void> | null = null;
function ensureWasm(): Promise<void> {
  wasmReady ??= (async () => { await initWasm(await Bun.file(wasmPath).arrayBuffer()); })();
  return wasmReady;
}

const RASTER_SCALE = 3;

/**
 * Как NSImage.draw(in:) в Swift: вся картинка SVG (её собственный размер) растягивается на canvas × scale.
 * Обёртка с preserveAspectRatio="none" даёт ровно W×H пикселей при любом соотношении сторон.
 */
function rasterize(svg: string, canvas: [number, number], scale: number): { w: number; h: number; rgba: Uint8Array } | null {
  const W = Math.max(Math.trunc(canvas[0] * scale), 1), H = Math.max(Math.trunc(canvas[1] * scale), 1);
  let iw: number, ih: number;
  try {
    const probe = new Resvg(svg);
    iw = probe.width; ih = probe.height;
    probe.free();
  } catch {
    return null;
  }
  if (!(iw > 0 && ih > 0)) return null;
  const wrapped = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${iw} ${ih}" preserveAspectRatio="none">${svg}</svg>`;
  const r = new Resvg(wrapped, { fitTo: { mode: "original" }, font: { loadSystemFonts: false } });
  const img = r.render();
  const out = { w: img.width, h: img.height, rgba: img.pixels };
  img.free(); r.free();
  if (out.w !== W || out.h !== H) return null;
  return out;
}

/** Обрезать прозрачные поля (alpha > 2). PNG + прямоугольник в координатах холста. */
function cropToContent(img: { w: number; h: number; rgba: Uint8Array }, scale: number): { png: Uint8Array; px: { width: number; height: number }; rect: ImageRect } | null {
  const { w, h, rgba } = img;
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y++) {
    const row = y * w * 4;
    for (let x = 0; x < w; x++) {
      if (rgba[row + x * 4 + 3] > 2) {
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  const cw = maxX - minX + 1, ch = maxY - minY + 1;
  const data = new Uint8Array(cw * ch * 4);
  for (let y = 0; y < ch; y++) {
    data.set(rgba.subarray(((minY + y) * w + minX) * 4, ((minY + y) * w + minX + cw) * 4), y * cw * 4);
  }
  // resvg отдаёт premultiplied RGBA, PNG — straight alpha.
  for (let p = 0; p < data.length; p += 4) {
    const a = data[p + 3];
    if (a === 0 || a === 255) continue;
    for (let c = 0; c < 3; c++) data[p + c] = Math.min(255, Math.round((data[p + c] * 255) / a));
  }
  const png = encodePNG({ width: cw, height: ch, data, channels: 4, depth: 8 });
  return {
    png, px: { width: cw, height: ch },
    rect: { x: minX / scale, y: minY / scale, width: cw / scale, height: ch / scale },
  };
}

// MARK: - Public API

/** Человекочитаемое имя из SVG: <title>, иначе id корневого <svg>. */
export function svgTitle(svgText: string): string | null {
  const first = (re: RegExp): string | null => {
    const m = re.exec(svgText);
    if (!m || m[1] === undefined) return null;
    const v = m[1].trim();
    return v === "" ? null : Array.from(v).slice(0, 60).join("");
  };
  return first(/<title[^>]*>(.*?)<\/title>/is) ?? first(/<svg[^>]*?\sid="([^"]+)"/is);
}

export async function svgToLottie(svgText: string): Promise<SVGImportResult> {
  const dom = parseSVG(svgText);
  if (!dom) throw new Error("Could not parse the SVG");
  const gradients = collectGradients(dom);
  const needsRaster = (a: Attrs) => needsRasterization(a, gradients);
  const rasterNodes = findRasterNodes(dom, (n) => needsRaster(n.attrs));

  const collector = new Collector(needsRaster);
  collector.walk(dom);
  collector.finish();
  if (collector.elements.length === 0) throw new Error("No supported shapes found in the SVG (rect/circle/ellipse/line/polygon/polyline/path)");

  const [w, h] = collector.size();
  const canvas: [number, number] = [w, h];
  const warnings = [...collector.warnings];
  if (rasterNodes.length > 0) {
    warnings.push(`${rasterNodes.length} element(s) with blur/mask/complex gradient imported as images (exact look, transform-only animation)`);
  }
  if (rasterNodes.length > 0) await ensureWasm();

  const assets: Obj[] = [];
  const rasterLayer = (el: Element, ind: number): Obj | null => {
    const i = Number(el.attrs["index"]);
    if (!(i < rasterNodes.length)) return null;
    const doc = isolate(rasterNodes[i], dom);
    const img = rasterize(doc, canvas, RASTER_SCALE);
    const cropped = img && cropToContent(img, RASTER_SCALE);
    if (!cropped) return null;
    const id = `svg_raster_${assets.length + 1}`;
    assets.push(imageAsset(id, cropped.png, cropped.px));
    return imageLayer(el.name, id, cropped.px, cropped.rect, ind, 1);
  };

  const makeLayer = (el: Element, ind: number): Obj | null => {
    if (el.tag === "__raster") return rasterLayer(el, ind);
    const a = el.attrs;
    const shapeItems: Obj[] = [];
    let bbox: BBox | null = null;
    switch (el.tag) {
      case "rect": {
        const x = num(a["x"]) ?? 0, y = num(a["y"]) ?? 0;
        const rw = num(a["width"]) ?? 0, rh = num(a["height"]) ?? 0;
        if (!(rw > 0 && rh > 0)) return null;
        const rx = num(a["rx"]) ?? 0;
        shapeItems.push({ ty: "rc", p: kStatic([x + rw / 2, y + rh / 2]), s: kStatic([rw, rh]), r: kScalar(rx), nm: "rect", hd: false });
        bbox = { minX: x, minY: y, maxX: x + rw, maxY: y + rh };
        break;
      }
      case "circle": {
        const cx = num(a["cx"]) ?? 0, cy = num(a["cy"]) ?? 0, r = num(a["r"]) ?? 0;
        if (!(r > 0)) return null;
        shapeItems.push({ ty: "el", p: kStatic([cx, cy]), s: kStatic([r * 2, r * 2]), nm: "ellipse", hd: false });
        bbox = { minX: cx - r, minY: cy - r, maxX: cx + r, maxY: cy + r };
        break;
      }
      case "ellipse": {
        const cx = num(a["cx"]) ?? 0, cy = num(a["cy"]) ?? 0;
        const rx = num(a["rx"]) ?? 0, ry = num(a["ry"]) ?? 0;
        if (!(rx > 0 && ry > 0)) return null;
        shapeItems.push({ ty: "el", p: kStatic([cx, cy]), s: kStatic([rx * 2, ry * 2]), nm: "ellipse", hd: false });
        bbox = { minX: cx - rx, minY: cy - ry, maxX: cx + rx, maxY: cy + ry };
        break;
      }
      case "line": {
        const x1 = num(a["x1"]) ?? 0, y1 = num(a["y1"]) ?? 0, x2 = num(a["x2"]) ?? 0, y2 = num(a["y2"]) ?? 0;
        shapeItems.push(shFromVertices([[x1, y1], [x2, y2]], false));
        bbox = bboxOf([[x1, y1], [x2, y2]]);
        break;
      }
      case "polygon": case "polyline": {
        const pts = points(a["points"]);
        if (pts.length < 2) return null;
        shapeItems.push(shFromVertices(pts, el.tag === "polygon"));
        bbox = bboxOf(pts);
        break;
      }
      case "path": {
        const parsed = parsePath(a["d"] ?? "");
        if (parsed.subpaths.length === 0) return null;
        if (parsed.approximated) {
          const msg = "Some paths use arcs (A) — approximated with line segments";
          if (!warnings.includes(msg)) warnings.push(msg);
        }
        const allV: number[][] = [];
        for (const sp of parsed.subpaths) { shapeItems.push(shFromBezier(sp)); allV.push(...sp.v); }
        bbox = bboxOf(allV);
        break;
      }
      default:
        return null;
    }
    if (!bbox) return null;
    const style = a["style"];

    // opacity="0" → невидимый элемент (артефакт SF Symbols / CoreSVG) — пропускаем.
    const elementOpacity = num(a["opacity"]) ?? styleNum(style, "opacity") ?? 1;
    if (!(elementOpacity > 0.001)) return null;

    const fillOpacity = num(a["fill-opacity"]) ?? styleNum(style, "fill-opacity") ?? 1;
    const strokeOpacity = num(a["stroke-opacity"]) ?? styleNum(style, "stroke-opacity") ?? 1;
    let fill = color(a["fill"], style, "fill");
    let stroke = color(a["stroke"], style, "stroke");
    if (fill) fill[3] *= fillOpacity;
    if (stroke) stroke[3] *= strokeOpacity;
    const strokeWidth = num(a["stroke-width"]) ?? styleNum(style, "stroke-width") ?? 1;

    const fRef = gradientRef(a["fill"] ?? styleValue(style, "fill"));
    const sRef = gradientRef(a["stroke"] ?? styleValue(style, "stroke"));
    const fillGradient = fRef === null ? undefined : gradients.get(fRef);
    const strokeGradient = sRef === null ? undefined : gradients.get(sRef);
    if (fillGradient) fill = null;
    if (strokeGradient) stroke = null;

    if (strokeGradient) shapeItems.push(gradientItem(strokeGradient, bbox, strokeOpacity, strokeWidth));
    else if (stroke) shapeItems.push(strokeItem(stroke, strokeWidth));
    if (fillGradient) shapeItems.push(gradientItem(fillGradient, bbox, fillOpacity, null));
    else if (fill) shapeItems.push(fillItem(fill));
    else if (!stroke && !strokeGradient) shapeItems.push(fillItem([0, 0, 0, 1])); // как SVG: дефолтный чёрный fill
    shapeItems.push(groupTransform());

    const group = { ty: "gr", it: shapeItems, nm: "Group", np: shapeItems.length, cix: 2, bm: 0, ix: 1, mn: "ADBE Vector Group", hd: false };
    const cx = (bbox.minX + bbox.maxX) / 2, cy = (bbox.minY + bbox.maxY) / 2;
    return {
      ddd: 0, ind, ty: 4, nm: el.name, sr: 1,
      ks: {
        o: kScalar(elementOpacity * 100, 11),
        r: kScalar(0, 10),
        p: kStatic([cx, cy, 0], 2),
        a: kStatic([cx, cy, 0], 1),
        s: kStatic([100, 100, 100], 6),
      },
      ao: 0, shapes: [group], ip: 0, op: 1, st: 0, bm: 0,
    };
  };

  // SVG рисует в порядке документа (последний — сверху), в Lottie layers[0] — сверху.
  const layers: Obj[] = [];
  const names: string[] = [];
  let ind = 1;
  for (const el of [...collector.elements].reverse()) {
    const layer = makeLayer(el, ind);
    if (!layer) continue;
    layers.push(layer);
    names.push(el.name);
    ind++;
  }
  names.reverse();
  if (layers.length === 0) throw new Error("No supported shapes found in the SVG (rect/circle/ellipse/line/polygon/polyline/path)");

  const bb = layersBoundingBox(layers);
  const compW = Math.ceil(Math.max(w, bb.maxX)), compH = Math.ceil(Math.max(h, bb.maxY));
  const lottie = { v: "5.7.0", fr: 60, ip: 0, op: 1, w: compW, h: compH, nm: "SVG Import", ddd: 0, assets, layers };
  return { lottie, layerNames: names, warnings };
}

function layersBoundingBox(layers: Obj[]): BBox {
  const result = { minX: 0, minY: 0, maxX: 0, maxY: 0 };
  const n = (v: any) => (typeof v === "number" ? v : 0);
  const collect = (shape: Obj, ox: number, oy: number) => {
    if (shape.ty === "sh") {
      for (const v of shape.ks?.k?.v ?? []) {
        if (!Array.isArray(v) || v.length < 2) continue;
        result.maxX = Math.max(result.maxX, ox + n(v[0]));
        result.maxY = Math.max(result.maxY, oy + n(v[1]));
      }
    } else if (shape.ty === "gr") {
      for (const it of shape.it ?? []) collect(it, ox, oy);
    }
  };
  for (const layer of layers) {
    const pos = layer.ks?.p?.k ?? [], anc = layer.ks?.a?.k ?? [];
    const ox = n(pos[0]) - n(anc[0]), oy = n(pos[1]) - n(anc[1]);
    for (const shape of layer.shapes ?? []) collect(shape, ox, oy);
  }
  return result;
}
