// Порт Sources/AI/Spec/LottieCompiler.swift (1:1 по поведению).
//
// Детерминированный компилятор: AnimationSpec + статичный Lottie → анимированный Lottie.
// Геометрия слоёв не меняется — впрыскиваются только keyframes в transform-каналы (ks: o/p/s/r),
// trim-path (tm), эффекты и цвета. Результат валиден по построению, если валиден вход.
//
// Swift работает со значениями ([String: Any] копируется при присваивании), поэтому здесь на всех
// границах, где Swift копирует, делаем deep clone — чтобы не было алиасинга между объектами.

import type { CompileResult, Lottie } from "./types";
import { maxDurationFrames, maxFPS, minFPS } from "./spec";
import type { AnimationSpec, Easing, GeneratedLayer, MotionParams, MotionPrimitive } from "./spec";

type Dict = Record<string, any>;

// MARK: - Swift-cast helpers (as? …)

function isDict(v: unknown): v is Dict {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** `as? [[String: Any]]` — массив, все элементы которого словари. */
function asDictArray(v: unknown): Dict[] | null {
  return Array.isArray(v) && v.every(isDict) ? v : null;
}

/** `as? [[Any]]` — массив массивов. */
function asArrayArray(v: unknown): any[][] | null {
  return Array.isArray(v) && v.every(Array.isArray) ? v : null;
}

/** `as? NSNumber` → doubleValue (JSON-булевы в Foundation — тоже NSNumber). */
function asNumber(v: unknown): number | null {
  if (typeof v === "number") return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  return null;
}

/** `as? Int` — только точно представимое в Int64 целое. */
function asInt(v: unknown): number | null {
  const n = asNumber(v);
  if (n === null || !Number.isInteger(n) || n >= 2 ** 63 || n < -(2 ** 63)) return null;
  return n;
}

function asString(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function clone<T>(v: T): T {
  return structuredClone(v);
}

/** Swift `rounded()` / `round()` — половина от нуля. */
function swiftRound(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

/** Целочисленное деление Swift (усечение к нулю). */
function idiv(a: number, b: number): number {
  return Math.trunc(a / b);
}

function clamp(value: number, lo: number, hi: number): number {
  return Math.min(Math.max(value, lo), hi);
}

function frame(seconds: number, fps: number): number {
  return Math.max(0, swiftRound(seconds * fps));
}

function normalizeScale(v: number): number {
  return v > 0 && v < 10 ? v * 100 : v;
}

/** Детерминированный псевдо-шум в [-1, 1] (как Swift: `seed &* 2654435761 % 10_000`, Int64). */
function pseudoNoise(seed: number): number {
  const prod = BigInt.asIntN(64, BigInt(seed) * 2654435761n);
  const x = Number(prod % 10000n) / 10000.0;
  return x * 2 - 1;
}

// MARK: - Easing presets (CSS cubic-bezier control points)

function bezier(easing: Easing): { ox: number; oy: number; ix: number; iy: number } {
  switch (easing) {
    case "linear": return { ox: 0, oy: 0, ix: 1, iy: 1 };
    case "easeIn": return { ox: 0.42, oy: 0, ix: 1, iy: 1 };
    case "easeOut": return { ox: 0, oy: 0, ix: 0.58, iy: 1 };
    case "easeInOut": return { ox: 0.42, oy: 0, ix: 0.58, iy: 1 };
    case "spring": return { ox: 0.34, oy: 1.2, ix: 0.64, iy: 1 };
    case "easeOutBack": return { ox: 0.34, oy: 1.56, ix: 0.64, iy: 1 };
    case "easeInBack": return { ox: 0.36, oy: 0, ix: 0.66, iy: -0.56 };
    case "easeInOutBack": return { ox: 0.68, oy: -0.6, ix: 0.32, iy: 1.6 };
    case "anticipate": return { ox: 0.4, oy: -0.3, ix: 0.6, iy: 1 };
    case "elastic": return { ox: 0.175, oy: 0.885, ix: 0.32, iy: 1.275 };
  }
}

// MARK: - Keyframe construction

/** Один keyframe. easing описывает переход ОТ этого keyframe к следующему; у последнего — нет. */
function kf(t: number, values: number[], easing?: Easing | null): Dict {
  const f: Dict = { t, s: [...values] };
  if (easing) {
    const b = bezier(easing);
    f.o = { x: [b.ox], y: [b.oy] };
    f.i = { x: [b.ix], y: [b.iy] };
  }
  return f;
}

/** Убирает дубли/невозрастающие t, гарантирует у последнего keyframe отсутствие i/o. */
function normalizeTimes(frames: Dict[], defaultValues: number[]): Dict[] {
  const result: Dict[] = [];
  let lastT = -Infinity;
  for (const f of frames) {
    let t = asInt(f.t) ?? 0;
    if (t <= lastT) t = lastT + 1;
    f.t = t;
    lastT = t;
    result.push(f);
  }
  if (result.length === 0) return [kf(0, defaultValues)];
  const last = result[result.length - 1]!;
  delete last.o;
  delete last.i;
  return result;
}

// MARK: - Base value readers

function scalarBase(ks: Dict, key: string, fallback: number): number {
  const ch = ks[key];
  if (!isDict(ch)) return fallback;
  const n = asNumber(ch.k);
  if (n !== null) return n;
  if (Array.isArray(ch.k)) {
    const first = asNumber(ch.k[0]);
    if (first !== null) return first;
  }
  return fallback;
}

function vectorBase(ks: Dict, key: string, fallback: number[]): number[] {
  const ch = ks[key];
  if (!isDict(ch) || !Array.isArray(ch.k)) return [...fallback];
  const values = ch.k.map(asNumber).filter((n): n is number => n !== null);
  return values.length === 0 ? [...fallback] : values;
}

function existingIx(ks: Dict, key: string): number | null {
  const ch = ks[key];
  return isDict(ch) ? asInt(ch.ix) : null;
}

// MARK: - Geometry helpers

/** Смещение базовой позиции для slide (direction — направление видимого движения). */
function offset(base: number[], direction: string | undefined, distance: number, reversed: boolean): number[] {
  let dx = 0;
  let dy = 0;
  switch (direction) {
    case "up": dy = +distance; break;
    case "down": dy = -distance; break;
    case "left": dx = +distance; break;
    case "right": dx = -distance; break;
    default: dy = +distance;
  }
  if (!reversed) { dx = -dx; dy = -dy; }
  return applied(base, dx, dy);
}

function applied(base: number[], dx: number, dy: number): number[] {
  const v = [...base];
  if (v.length >= 2) {
    v[0]! += dx;
    v[1]! += dy;
  }
  return v;
}

// MARK: - Channel writers

function mergeKeyframes(existing: unknown, next: Dict[]): Dict[] {
  if (!isDict(existing) || asInt(existing.a) !== 1) return next;
  const old = asDictArray(existing.k);
  if (!old) return next;
  const newStart = next.length > 0 ? asInt(next[0]!.t) : null;
  if (newStart === null) return next;
  const base = old.filter((f) => (asInt(f.t) ?? 0) < newStart).map((f) => clone(f));
  if (base.length > 0) {
    const last = base[base.length - 1]!;
    delete last.o;
    delete last.i;
    last.h = 1;
  }
  return [...base, ...next];
}

function setChannel(ks: Dict, key: string, ix: number, keyframes: Dict[]): void {
  const resolvedIx = existingIx(ks, key) ?? ix;
  const merged = mergeKeyframes(ks[key], keyframes);
  ks[key] = { a: 1, k: merged, ix: resolvedIx };
}

const setScalar = setChannel;
const setVector = setChannel;

// MARK: - Composite keyframe generators

function pulseKeyframes(startFrame: number, endFrame: number, peak: number, repeats: number, easing: Easing): Dict[] {
  const frames: Dict[] = [];
  const total = endFrame - startFrame;
  const perCycle = Math.max(2, idiv(total, repeats));
  let t = startFrame;
  for (let r = 0; r < repeats; r++) {
    const mid = t + idiv(perCycle, 2);
    const endCycle = t + perCycle;
    frames.push(kf(t, [100, 100, 100], easing));
    frames.push(kf(mid, [peak, peak, 100], easing));
    frames.push(kf(endCycle, [100, 100, 100], easing));
    t = endCycle;
  }
  return normalizeTimes(frames, [100, 100, 100]);
}

function bounceKeyframes(base: number[], startFrame: number, endFrame: number, amount: number): Dict[] {
  const mid = startFrame + idiv(endFrame - startFrame, 2);
  const up = applied(base, 0, -amount);
  return [kf(startFrame, base, "easeOut"), kf(mid, up, "easeIn"), kf(endFrame, base)];
}

function wiggleKeyframes(base: number[], startFrame: number, endFrame: number, amount: number, frequency: number): Dict[] {
  const steps = Math.max(2, frequency * 2);
  const frames: Dict[] = [];
  const span = endFrame - startFrame;
  for (let i = 0; i <= steps; i++) {
    const t = startFrame + swiftRound((span * i) / steps);
    const dx = pseudoNoise(i * 2 + 1) * amount;
    const dy = pseudoNoise(i * 2 + 7) * amount;
    const values = i === 0 || i === steps ? base : applied(base, dx, dy);
    frames.push(kf(t, values, "easeInOut"));
  }
  return normalizeTimes(frames, base);
}

function floatKeyframes(base: number[], startFrame: number, endFrame: number, amount: number): Dict[] {
  const mid = startFrame + idiv(endFrame - startFrame, 2);
  return normalizeTimes(
    [kf(startFrame, base, "easeInOut"), kf(mid, applied(base, 0, -amount), "easeInOut"), kf(endFrame, base)],
    base,
  );
}

function swingKeyframes(base: number, startFrame: number, endFrame: number, amount: number): Dict[] {
  const span = endFrame - startFrame;
  const q1 = startFrame + idiv(span, 4);
  const q3 = startFrame + idiv(span * 3, 4);
  return normalizeTimes(
    [
      kf(startFrame, [base], "easeInOut"),
      kf(q1, [base + amount], "easeInOut"),
      kf(q3, [base - amount], "easeInOut"),
      kf(endFrame, [base]),
    ],
    [base],
  );
}

function followPathKeyframes(base: number[], points: number[][], startFrame: number, endFrame: number, easing: Easing): Dict[] {
  const count = points.length;
  const span = endFrame - startFrame;
  const frames: Dict[] = [];
  points.forEach((pt, i) => {
    const t = startFrame + (count <= 1 ? 0 : swiftRound((span * i) / (count - 1)));
    const px = pt.length > 0 ? pt[0]! : 0;
    const py = pt.length > 1 ? pt[1]! : 0;
    const x = base.length > 0 ? base[0]! + px : px;
    const y = base.length > 1 ? base[1]! + py : py;
    const z = base.length > 2 ? base[2]! : 0.0;
    frames.push(kf(t, [x, y, z], i < count - 1 ? easing : null));
  });
  return normalizeTimes(frames, base);
}

function flashKeyframes(startFrame: number, endFrame: number, low: number, repeats: number, easing: Easing): Dict[] {
  const frames: Dict[] = [];
  const total = endFrame - startFrame;
  const perCycle = Math.max(2, idiv(total, repeats));
  let t = startFrame;
  for (let r = 0; r < repeats; r++) {
    const mid = t + idiv(perCycle, 2);
    const endCycle = t + perCycle;
    frames.push(kf(t, [100], easing));
    frames.push(kf(mid, [low], easing));
    frames.push(kf(endCycle, [100]));
    t = endCycle;
  }
  return normalizeTimes(frames, [100]);
}

// MARK: - Shapes / trim / mattes

function containsType(shapes: Dict[], type: string): boolean {
  for (const s of shapes) {
    if (asString(s.ty) === type) return true;
    if (asString(s.ty) === "gr") {
      const items = asDictArray(s.it);
      if (items && containsType(items, type)) return true;
    }
  }
  return false;
}

function makeTrimWithOffset(startFrame: number, endFrame: number, easing: Easing, off: number, ix: number): Dict {
  return {
    ty: "tm",
    s: { a: 0, k: 0, ix: 1 },
    e: { a: 1, k: [kf(startFrame, [0], easing), kf(endFrame, [100])], ix: 2 },
    o: { a: 0, k: off, ix: 3 },
    m: 1,
    nm: "Trim Paths (drawOn)",
    ix,
  };
}

function makeTrim(startFrame: number, endFrame: number, easing: Easing, ix: number): Dict {
  return makeTrimWithOffset(startFrame, endFrame, easing, 0, ix);
}

/** Для слоёв со штрихами: вставляет trim path рядом со stroke в каждой группе. */
function injectTrimOnStrokes(shapes: Dict[], startFrame: number, endFrame: number, easing: Easing): void {
  for (const shape of shapes) {
    if (asString(shape.ty) !== "gr") continue;
    const items = asDictArray(shape.it);
    if (!items) continue;
    if (items.some((it) => asString(it.ty) === "gr")) {
      injectTrimOnStrokes(items, startFrame, endFrame, easing);
    } else if (containsType(items, "st")) {
      let trimIdx = items.length;
      for (let j = items.length - 1; j >= 0; j--) {
        if (asString(items[j]!.ty) === "tr") { trimIdx = j; break; }
      }
      const trim = makeTrim(startFrame, endFrame, easing, items.length + 1);
      items.splice(trimIdx, 0, trim);
    }
  }
}

function extractShapePaths(shapes: Dict[]): Dict[] {
  const result: Dict[] = [];
  for (const s of shapes) {
    if (asString(s.ty) === "sh") result.push(s);
    if (asString(s.ty) === "gr") {
      const items = asDictArray(s.it);
      if (items) result.push(...extractShapePaths(items));
    }
  }
  return result;
}

function pathVertices(pathShape: Dict): any[][] | null {
  const ks = pathShape.ks;
  if (!isDict(ks)) return null;
  const k = ks.k;
  if (!isDict(k)) return null;
  return asArrayArray(k.v);
}

/** Trim offset (градусы), чтобы рисование начиналось с верхней правой вершины. */
function trimStartOffset(pathShape: Dict): number {
  const v = pathVertices(pathShape);
  if (!v || v.length <= 1) return 0;
  let bestIdx = 0;
  let bestScore = Infinity;
  v.forEach((pt, i) => {
    const x = asNumber(pt[0]);
    const y = asNumber(pt[1]);
    if (x === null || y === null) return;
    const score = y - x * 0.01;
    if (score < bestScore) { bestScore = score; bestIdx = i; }
  });
  return (360.0 * bestIdx) / v.length;
}

function pathRadius(pathShape: Dict): number {
  const v = pathVertices(pathShape);
  if (!v) return 10;
  const xs: number[] = [];
  const ys: number[] = [];
  for (const pt of v) {
    const x = asNumber(pt[0]);
    if (x !== null) xs.push(x);
    if (pt.length > 1) {
      const y = asNumber(pt[1]);
      if (y !== null) ys.push(y);
    }
  }
  if (xs.length === 0) return 10;
  const xr = Math.max(...xs) - Math.min(...xs);
  // В Swift пустой ys здесь — краш (ys.max()!); берём 0, чтобы не падать.
  const yr = ys.length > 0 ? Math.max(...ys) - Math.min(...ys) : 0;
  return Math.max(xr, yr) / 2;
}

const identityShapeTransform = (): Dict => ({
  ty: "tr",
  p: { a: 0, k: [0, 0] },
  a: { a: 0, k: [0, 0] },
  s: { a: 0, k: [100, 100] },
  r: { a: 0, k: 0 },
  o: { a: 0, k: 100 },
});

/** Track-matte слой: невидимый штрих+trim, который прогрессивно раскрывает оригинальный слой. */
function buildDrawOnMatte(
  targetLayer: Dict, shapes: Dict[], startFrame: number, endFrame: number,
  easing: Easing, duration: number, matteInd: number,
): Dict | null {
  const paths = extractShapePaths(shapes);
  if (paths.length === 0) return null;

  let mattePath: Dict;
  let strokeWidth: number;
  if (paths.length >= 2) {
    mattePath = paths[1]!;
    const r0 = pathRadius(paths[0]!);
    const r1 = pathRadius(paths[1]!);
    strokeWidth = Math.abs(r0 - r1) * 4 + r0 * 0.3;
  } else {
    mattePath = paths[0]!;
    strokeWidth = pathRadius(paths[0]!);
  }

  const trimOffset = trimStartOffset(mattePath);
  const stroke: Dict = {
    ty: "st",
    c: { a: 0, k: [1, 1, 1, 1] },
    o: { a: 0, k: 100 },
    w: { a: 0, k: strokeWidth },
    lc: 2, lj: 2,
    nm: "Matte Stroke",
  };
  const trim = makeTrimWithOffset(startFrame, endFrame, easing, trimOffset, 3);
  const group: Dict = { ty: "gr", it: [clone(mattePath), stroke, trim, identityShapeTransform()], nm: "Matte Group" };

  return {
    ty: 4,
    nm: "drawOn-matte",
    shapes: [group],
    ip: 0,
    op: duration,
    st: 0,
    sr: 1,
    td: 1,
    ks: clone(targetLayer.ks ?? {}),
    ind: matteInd,
  };
}

function buildClipMatte(compW: number, compH: number, duration: number, matteInd: number): Dict {
  const rect: Dict = {
    ty: "rc",
    d: 1,
    s: { a: 0, k: [compW, compH] },
    p: { a: 0, k: [0, 0] },
    r: { a: 0, k: 0 },
    nm: "Clip Rect",
  };
  const fill: Dict = { ty: "fl", c: { a: 0, k: [1, 1, 1, 1] }, o: { a: 0, k: 100 }, nm: "Clip Fill" };
  const group: Dict = { ty: "gr", it: [rect, fill, identityShapeTransform()], nm: "Clip Group" };
  return {
    ty: 4,
    nm: "clip-matte",
    shapes: [group],
    ip: 0,
    op: duration,
    st: 0,
    sr: 1,
    td: 1,
    ks: {
      o: { a: 0, k: 100, ix: 11 },
      p: { a: 0, k: [compW / 2, compH / 2, 0], ix: 2 },
      a: { a: 0, k: [0, 0, 0], ix: 1 },
      s: { a: 0, k: [100, 100, 100], ix: 6 },
      r: { a: 0, k: 0, ix: 10 },
    },
    ind: matteInd,
  };
}

// MARK: - Blur

function applyBlurEffect(layer: Dict, fromBlur: number, toBlur: number, startFrame: number, endFrame: number, easing: Easing): void {
  const blurriness: Dict = {
    ty: 0,
    nm: "Blurriness",
    mn: "ADBE Gaussian Blur 2-0001",
    ix: 1,
    v: { a: 1, k: [kf(startFrame, [fromBlur], easing), kf(endFrame, [toBlur])] },
  };
  const dimensions: Dict = { ty: 7, nm: "Blur Dimensions", mn: "ADBE Gaussian Blur 2-0002", ix: 2, v: { a: 0, k: 1 } };
  const repeatEdge: Dict = { ty: 7, nm: "Repeat Edge Pixels", mn: "ADBE Gaussian Blur 2-0003", ix: 3, v: { a: 0, k: 1 } };
  const blur: Dict = {
    ty: 29,
    nm: "Gaussian Blur",
    np: 5,
    mn: "ADBE Gaussian Blur 2",
    ix: 1,
    en: 1,
    ef: [blurriness, dimensions, repeatEdge],
  };
  const effects = asDictArray(layer.ef) ?? [];
  effects.push(blur);
  layer.ef = effects;
}

// MARK: - Shape editing

function stripShapeType(shapes: Dict[], type: string): Dict[] {
  const out = shapes.map((s) => {
    const ty = asString(s.ty);
    if (ty === type) return {};
    if (ty === "gr") {
      const items = asDictArray(s.it);
      if (items) s.it = stripShapeType(items, type).filter((d) => Object.keys(d).length > 0);
    }
    return s;
  });
  return out.filter((d) => Object.keys(d).length > 0);
}

function injectShapeItem(shapes: Dict[], item: Dict): void {
  for (const s of shapes) {
    if (asString(s.ty) !== "gr") continue;
    const items = asDictArray(s.it);
    if (!items) continue;
    let trIdx = items.length;
    for (let j = items.length - 1; j >= 0; j--) {
      if (asString(items[j]!.ty) === "tr") { trIdx = j; break; }
    }
    items.splice(trIdx, 0, item);
    return;
  }
  shapes.push(item);
}

// MARK: - Color

/** "#RRGGBB" / "#RGB" → [r, g, b, 1]; поведение как у Swift `UInt32(str, radix: 16)` (допускает знак). */
function parseHex(hex: string): number[] | null {
  let h = hex;
  if (h.startsWith("#")) h = h.slice(1);
  const chars = Array.from(h);
  let str: string;
  if (chars.length === 3) str = chars.map((c) => c + c).join("");
  else if (chars.length === 6) str = chars.join("");
  else return null;
  if (!/^[+-]?[0-9a-fA-F]+$/.test(str)) return null;
  let val = parseInt(str, 16);
  if (val < 0 || Object.is(val, -0)) {
    if (val !== 0) return null; // отрицательное не влезает в UInt32
    val = 0;
  }
  const r = ((val >> 16) & 0xff) / 255.0;
  const g = ((val >> 8) & 0xff) / 255.0;
  const b = (val & 0xff) / 255.0;
  return [r, g, b, 1];
}

function recolorShapes(shapes: Dict[], rgba: number[]): void {
  for (const s of shapes) {
    const ty = asString(s.ty);
    if (ty === "fl" || ty === "st") {
      if (isDict(s.c)) {
        s.c.a = 0;
        s.c.k = [...rgba];
      }
    } else if (ty === "gr") {
      const items = asDictArray(s.it);
      if (items) recolorShapes(items, rgba);
    }
  }
}

function colorTransitionShapes(shapes: Dict[], from: number[], to: number[], startFrame: number, endFrame: number, easing: Easing): void {
  for (const s of shapes) {
    const ty = asString(s.ty);
    if (ty === "fl" || ty === "st") {
      if (isDict(s.c)) {
        s.c.a = 1;
        s.c.k = [kf(startFrame, from, easing), kf(endFrame, to)];
      }
    } else if (ty === "gr") {
      const items = asDictArray(s.it);
      if (items) colorTransitionShapes(items, from, to, startFrame, endFrame, easing);
    }
  }
}

function findFirstColor(shapes: Dict[]): number[] | null {
  for (const s of shapes) {
    const ty = asString(s.ty);
    if (ty === "fl" || ty === "st") {
      if (isDict(s.c) && Array.isArray(s.c.k)) {
        const vals = s.c.k.map(asNumber).filter((n: number | null): n is number => n !== null);
        if (vals.length >= 3) return vals;
      }
    } else if (ty === "gr") {
      const items = asDictArray(s.it);
      if (items) {
        const found = findFirstColor(items);
        if (found) return found;
      }
    }
  }
  return null;
}

// MARK: - Generated layers

function buildGeneratedLayer(gen: GeneratedLayer, anchorLayer: Dict, ind: number, duration: number): Dict {
  const anchorKs = isDict(anchorLayer.ks) ? anchorLayer.ks : {};
  const pos = vectorBase(anchorKs, "p", [0, 0, 0]);
  const w = gen.width ?? 100;
  const h = gen.height ?? 100;
  const opacity = gen.opacity ?? 0;

  const shapeItem: Dict = gen.shape === "ellipse"
    ? { ty: "el", p: { a: 0, k: [0, 0] }, s: { a: 0, k: [w, h] }, nm: "Ellipse" }
    : { ty: "rc", d: 1, p: { a: 0, k: [0, 0] }, s: { a: 0, k: [w, h] }, r: { a: 0, k: 0 }, nm: "Rect" };

  const groupItems: Dict[] = [shapeItem];
  const fillRGBA = gen.fillColor !== undefined ? parseHex(gen.fillColor) : null;
  if (fillRGBA) groupItems.push({ ty: "fl", c: { a: 0, k: fillRGBA }, o: { a: 0, k: 100 }, nm: "Fill" });
  const strokeRGBA = gen.strokeColor !== undefined ? parseHex(gen.strokeColor) : null;
  if (strokeRGBA) {
    groupItems.push({
      ty: "st", c: { a: 0, k: strokeRGBA }, o: { a: 0, k: 100 },
      w: { a: 0, k: gen.strokeWidth ?? 2 }, lc: 2, lj: 2, nm: "Stroke",
    });
  }
  if (gen.fillColor === undefined && gen.strokeColor === undefined) {
    groupItems.push({ ty: "fl", c: { a: 0, k: [1, 1, 1, 1] }, o: { a: 0, k: 100 }, nm: "Fill" });
  }
  groupItems.push(identityShapeTransform());

  return {
    ty: 4, nm: gen.name, ind, ip: 0, op: duration, st: 0, sr: 1,
    shapes: [{ ty: "gr", it: groupItems, nm: "Generated Group" }],
    ks: {
      o: { a: 0, k: opacity, ix: 11 },
      p: { a: 0, k: pos, ix: 2 },
      a: { a: 0, k: [0, 0, 0], ix: 1 },
      s: { a: 0, k: [100, 100, 100], ix: 6 },
      r: { a: 0, k: 0, ix: 10 },
    },
  };
}

// MARK: - Wildcard matching

function matchWildcard(pattern: string, indexByName: Map<string, number>): { name: string; idx: number }[] {
  let pred: ((name: string) => boolean) | null = null;
  if (pattern.endsWith("*")) {
    const prefix = pattern.slice(0, -1);
    pred = (n) => n.startsWith(prefix);
  } else if (pattern.startsWith("*")) {
    const suffix = pattern.slice(1);
    pred = (n) => n.endsWith(suffix);
  }
  if (!pred) return [];
  return [...indexByName.entries()]
    .filter(([name]) => pred!(name))
    .sort((a, b) => a[1] - b[1])
    .map(([name, idx]) => ({ name, idx }));
}

function buildIndex(layers: Dict[]): Map<string, number> {
  const index = new Map<string, number>();
  layers.forEach((layer, idx) => {
    const name = asString(layer.nm);
    if (name !== null && !index.has(name)) index.set(name, idx);
  });
  return index;
}

// MARK: - Primitive dispatch

interface PrimitiveContext {
  ks: Dict;
  originalKs: Dict;
  layer: Dict;
  fps: number;
  warnings: string[];
  targetName: string;
  needsClip: boolean;
}

function applyPrimitive(primitive: MotionPrimitive, ctx: PrimitiveContext): void {
  const { ks, originalKs, fps, warnings, targetName } = ctx;
  const startFrame = frame(primitive.start, fps);
  let endFrame = frame(primitive.end, fps);
  if (endFrame <= startFrame) endFrame = startFrame + 1; // защита от нулевой длительности
  const p: MotionParams = primitive.params ?? {};
  const easing = primitive.easing;

  switch (primitive.kind) {
    case "fadeIn":
      setScalar(ks, "o", 11, [kf(startFrame, [0], easing), kf(endFrame, [100])]);
      break;
    case "fadeOut":
      setScalar(ks, "o", 11, [kf(startFrame, [100], easing), kf(endFrame, [0])]);
      break;
    case "slideIn": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      const from = offset(base, p.direction, p.distance ?? 100, false);
      setVector(ks, "p", 2, [kf(startFrame, from, easing), kf(endFrame, base)]);
      ctx.needsClip = true;
      break;
    }
    case "slideOut": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      const to = offset(base, p.direction, p.distance ?? 100, false);
      setVector(ks, "p", 2, [kf(startFrame, base, easing), kf(endFrame, to)]);
      ctx.needsClip = true;
      break;
    }
    case "scaleIn": {
      const from = normalizeScale(p.from ?? 0);
      const to = normalizeScale(p.to ?? 100);
      setVector(ks, "s", 6, [kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])]);
      break;
    }
    case "scaleOut": {
      const from = normalizeScale(p.from ?? 100);
      const to = normalizeScale(p.to ?? 0);
      setVector(ks, "s", 6, [kf(startFrame, [from, from, 100], easing), kf(endFrame, [to, to, 100])]);
      break;
    }
    case "rotate": {
      const base = scalarBase(originalKs, "r", 0);
      const from = p.fromDeg ?? base;
      const to = p.toDeg ?? base + 360;
      setScalar(ks, "r", 10, [kf(startFrame, [from], easing), kf(endFrame, [to])]);
      break;
    }
    case "pulse": {
      const peak = normalizeScale(p.amount ?? 110);
      const repeats = Math.max(1, p.repeatCount ?? 1);
      setVector(ks, "s", 6, pulseKeyframes(startFrame, endFrame, peak, repeats, easing));
      break;
    }
    case "bounce": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      setVector(ks, "p", 2, bounceKeyframes(base, startFrame, endFrame, p.amount ?? 20));
      break;
    }
    case "wiggle": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      const freq = Math.max(1, swiftRound(p.frequency ?? 4));
      setVector(ks, "p", 2, wiggleKeyframes(base, startFrame, endFrame, p.amount ?? 10, freq));
      break;
    }
    case "drawOn":
      break; // drawOn обрабатывается в compile() через trim / track matte
    case "spin": {
      const base = scalarBase(originalKs, "r", 0);
      const turns = Math.max(1, p.repeatCount ?? 1);
      setScalar(ks, "r", 10, [kf(startFrame, [base], "linear"), kf(endFrame, [base + 360 * turns])]);
      break;
    }
    case "float": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      setVector(ks, "p", 2, floatKeyframes(base, startFrame, endFrame, p.amount ?? 12));
      break;
    }
    case "breathe": {
      const peak = normalizeScale(p.amount ?? 106);
      setVector(ks, "s", 6, pulseKeyframes(startFrame, endFrame, peak, Math.max(1, p.repeatCount ?? 1), "easeInOut"));
      break;
    }
    case "swing": {
      const base = scalarBase(originalKs, "r", 0);
      setScalar(ks, "r", 10, swingKeyframes(base, startFrame, endFrame, p.amount ?? 10));
      break;
    }
    case "followPath": {
      const base = vectorBase(originalKs, "p", [0, 0, 0]);
      if (p.path && p.path.length >= 2) {
        setVector(ks, "p", 2, followPathKeyframes(base, p.path, startFrame, endFrame, easing));
      } else {
        warnings.push(`Layer '${targetName}': followPath needs params.path with ≥2 points — skipped`);
      }
      break;
    }
    case "recolor": {
      const rgba = p.color !== undefined ? parseHex(p.color) : null;
      if (rgba) {
        const shapes = asDictArray(ctx.layer.shapes);
        if (shapes) recolorShapes(shapes, rgba);
      } else {
        warnings.push(`Layer '${targetName}': recolor needs params.color (hex) — skipped`);
      }
      break;
    }
    case "squash":
    case "stretch": {
      const amount = normalizeScale(p.amount ?? 130);
      const inverse = 10000.0 / amount;
      const mid = startFrame + idiv(endFrame - startFrame, 2);
      const peak = primitive.kind === "squash" ? [amount, inverse, 100] : [inverse, amount, 100];
      setVector(ks, "s", 6, [
        kf(startFrame, [100, 100, 100], easing),
        kf(mid, peak, easing),
        kf(endFrame, [100, 100, 100]),
      ]);
      break;
    }
    case "flash": {
      const low = p.amount ?? 0;
      const repeats = Math.max(1, p.repeatCount ?? 1);
      setScalar(ks, "o", 11, flashKeyframes(startFrame, endFrame, low, repeats, easing));
      break;
    }
    case "flip": {
      ctx.layer.ddd = 1;
      const flipAxis = p.axis === "x" ? "rx" : "ry";
      const ixVal = p.axis === "x" ? 8 : 9;
      const from = p.fromDeg ?? 0;
      const to = p.toDeg ?? 180;
      setScalar(ks, flipAxis, ixVal, [kf(startFrame, [from], easing), kf(endFrame, [to])]);
      break;
    }
    case "colorTransition": {
      const toRGBA = p.color !== undefined ? parseHex(p.color) : null;
      if (toRGBA) {
        const parsedFrom = p.fromColor !== undefined ? parseHex(p.fromColor) : null;
        const shapes = asDictArray(ctx.layer.shapes);
        const fromRGBA = parsedFrom ?? (shapes ? findFirstColor(shapes) : null) ?? [0, 0, 0, 1];
        if (shapes) colorTransitionShapes(shapes, fromRGBA, toRGBA, startFrame, endFrame, easing);
      } else {
        warnings.push(`Layer '${targetName}': colorTransition needs params.color — skipped`);
      }
      break;
    }
    case "blurIn":
      applyBlurEffect(ctx.layer, p.blurAmount ?? 20, 0, startFrame, endFrame, easing);
      break;
    case "blurOut":
      applyBlurEffect(ctx.layer, 0, p.blurAmount ?? 20, startFrame, endFrame, easing);
      break;
    // M6 — shape-edit (мгновенные)
    case "removeFill":
    case "removeStroke": {
      const shapes = asDictArray(ctx.layer.shapes);
      if (shapes) ctx.layer.shapes = stripShapeType(shapes, primitive.kind === "removeFill" ? "fl" : "st");
      break;
    }
    case "addStroke": {
      const rgba = parseHex(p.color ?? "#FFFFFF") ?? [1, 1, 1, 1];
      const w = p.strokeWidth ?? 2;
      const shapes = asDictArray(ctx.layer.shapes);
      if (shapes) {
        injectShapeItem(shapes, {
          ty: "st", c: { a: 0, k: rgba }, o: { a: 0, k: 100 },
          w: { a: 0, k: w }, lc: 2, lj: 2, nm: "Added Stroke",
        });
      }
      break;
    }
    case "addFill": {
      const rgba = parseHex(p.color ?? "#FFFFFF") ?? [1, 1, 1, 1];
      const shapes = asDictArray(ctx.layer.shapes);
      if (shapes) injectShapeItem(shapes, { ty: "fl", c: { a: 0, k: rgba }, o: { a: 0, k: 100 }, nm: "Added Fill" });
      break;
    }
    case "hideLayer":
      ks.o = { a: 0, k: 0, ix: 11 };
      break;
    case "showLayer":
      ks.o = { a: 0, k: 100, ix: 11 };
      break;
  }
}

// MARK: - Compile

/**
 * Компилирует spec поверх статичного Lottie. Вход не мутируется (работаем с глубокой копией).
 * Бросает Error, если вход — не объект с массивом слоёв-объектов.
 */
export function compile(staticLottie: Lottie, spec: AnimationSpec): CompileResult {
  if (!isDict(staticLottie) || !asDictArray(staticLottie.layers)) {
    throw new Error("Static Lottie JSON is not a valid object with layers");
  }
  const root: Dict = clone(staticLottie);
  const layers: Dict[] = root.layers;

  const fps = clamp(spec.fps, minFPS, maxFPS);
  const duration = clamp(spec.durationFrames, 1, maxDurationFrames);
  const compW = asNumber(root.w) ?? 100;
  const compH = asNumber(root.h) ?? 100;
  const warnings: string[] = [];

  // Индекс слоёв по имени. При дублирующихся именах берём первый.
  let indexByName = buildIndex(layers);

  // Phase 0: generated layers
  const inds = layers.map((l) => asInt(l.ind)).filter((n): n is number => n !== null);
  let nextInd = (inds.length > 0 ? Math.max(...inds) : 0) + 1;
  if (spec.generatedLayers) {
    const newLayers: Dict[] = [];
    for (const gen of spec.generatedLayers) {
      if (indexByName.has(gen.name)) {
        warnings.push(`Generated layer '${gen.name}': name conflicts with existing layer — skipped`);
        continue;
      }
      const anchorIdx = indexByName.get(gen.anchor);
      if (anchorIdx === undefined) {
        warnings.push(`Generated layer '${gen.name}': anchor '${gen.anchor}' not found — skipped`);
        continue;
      }
      newLayers.push(buildGeneratedLayer(gen, layers[anchorIdx]!, nextInd, duration));
      nextInd += 1;
    }
    if (newLayers.length > 0) {
      layers.unshift(...newLayers);
      indexByName = buildIndex(layers);
    }
  }

  const matteInserts: { layerIdx: number; matte: Dict }[] = [];
  const clipInserts: { layerIdx: number; matte: Dict }[] = [];
  const maxInd = nextInd;

  for (const layerSpec of spec.layers) {
    let matches: { name: string; idx: number }[];
    if (layerSpec.target.includes("*")) {
      matches = matchWildcard(layerSpec.target, indexByName);
    } else {
      const idx = indexByName.get(layerSpec.target);
      matches = idx !== undefined ? [{ name: layerSpec.target, idx }] : [];
    }

    if (matches.length === 0) {
      warnings.push(`Layer '${layerSpec.target}' not found — animations skipped`);
      continue;
    }

    const stagger = layerSpec.staggerDelay ?? 0;

    matches.forEach((match, matchIndex) => {
      const idx = match.idx;
      const timeOffset = stagger * matchIndex;

      const layer: Dict = layers[idx]!;
      const ks: Dict = isDict(layer.ks) ? clone(layer.ks) : {};
      const ctx: PrimitiveContext = {
        ks,
        originalKs: clone(ks),
        layer,
        fps,
        warnings,
        targetName: match.name,
        needsClip: false,
      };

      for (const primitive of layerSpec.animations) {
        const p: MotionPrimitive = timeOffset > 0
          ? { ...primitive, start: primitive.start + timeOffset, end: primitive.end + timeOffset }
          : primitive;

        if (p.kind === "drawOn") {
          const startFrame = frame(p.start, fps);
          let endFrame = frame(p.end, fps);
          if (endFrame <= startFrame) endFrame = startFrame + 1;
          const shapes = asDictArray(layer.shapes) ?? [];

          if (containsType(shapes, "st")) {
            injectTrimOnStrokes(shapes, startFrame, endFrame, p.easing);
            layer.shapes = shapes;
          } else {
            const matte = buildDrawOnMatte(
              layer, shapes, startFrame, endFrame, p.easing, duration,
              maxInd + 100 + matteInserts.length,
            );
            if (matte) matteInserts.push({ layerIdx: idx, matte });
          }
        } else {
          applyPrimitive(p, ctx);
        }
      }

      layer.ks = ks;
      layer.ip = 0;
      layer.op = duration;

      const hasDrawOnMatte = matteInserts.some((m) => m.layerIdx === idx);
      if (ctx.needsClip && !hasDrawOnMatte) {
        clipInserts.push({
          layerIdx: idx,
          matte: buildClipMatte(compW, compH, duration, maxInd + 300 + clipInserts.length),
        });
      }
    });
  }

  // Стабильная сортировка по убыванию индекса (как Swift sorted) — вставки не сдвигают ещё не обработанные.
  const allInserts = [...matteInserts, ...clipInserts].sort((a, b) => b.layerIdx - a.layerIdx);
  for (const insert of allInserts) {
    layers[insert.layerIdx]!.tt = 1;
    layers.splice(insert.layerIdx, 0, insert.matte);
  }

  // Неанимированные слои, которые жили до конца исходной композиции, живут и до конца новой.
  const originalOp = asNumber(root.op) ?? 0;
  for (const layer of layers) {
    const op = asNumber(layer.op);
    if (op !== null && op >= originalOp && op < duration) layer.op = duration;
  }

  root.layers = layers;
  root.fr = fps;
  root.ip = 0;
  root.op = duration;
  return { lottie: root, warnings };
}

// MARK: - Animation inspector

/** printf("%.Nf") — округление по точному двоичному значению, ничьи к чётному. */
function formatFixed(x: number, digits: number): string {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x < 0 ? "-inf" : "inf";
  const negative = x < 0 || Object.is(x, -0);
  const abs = Math.abs(x);
  if (abs >= 1e21) return (negative ? "-" : "") + BigInt(abs).toString() + (digits > 0 ? "." + "0".repeat(digits) : "");
  const exact = abs.toFixed(100); // точная десятичная запись double (для |x| < 1e21)
  const dot = exact.indexOf(".");
  const intPart = exact.slice(0, dot);
  const frac = exact.slice(dot + 1);
  let kept = intPart + frac.slice(0, digits);
  const rest = frac.slice(digits);
  const first = rest[0] ?? "0";
  const tail = rest.slice(1);
  let roundUp = false;
  if (first > "5") roundUp = true;
  else if (first === "5") {
    if (/[1-9]/.test(tail)) roundUp = true;
    else roundUp = Number(kept[kept.length - 1]) % 2 === 1; // ничья → к чётному
  }
  if (roundUp) kept = (BigInt(kept) + 1n).toString().padStart(kept.length, "0");
  const ip = kept.slice(0, kept.length - digits) || "0";
  const fp = kept.slice(kept.length - digits);
  return (negative ? "-" : "") + ip + (digits > 0 ? "." + fp : "");
}

/** NSNumber.intValue — усечение к нулю. */
function intValue(v: unknown): number | null {
  const n = asNumber(v);
  return n === null ? null : Math.trunc(n);
}

function hasAnimatedProperty(shapes: Dict[], types: string[], prop: string): boolean {
  for (const s of shapes) {
    const ty = asString(s.ty) ?? "";
    if (types.includes(ty) && isDict(s[prop]) && asInt(s[prop].a) === 1) return true;
    if (ty === "gr") {
      const items = asDictArray(s.it);
      if (items && hasAnimatedProperty(items, types, prop)) return true;
    }
  }
  return false;
}

function containsTrimPath(shapes: Dict[]): boolean {
  for (const s of shapes) {
    if (asString(s.ty) === "tm") return true;
    if (asString(s.ty) === "gr") {
      const items = asDictArray(s.it);
      if (items && containsTrimPath(items)) return true;
    }
  }
  return false;
}

/** Текстовая сводка анимаций по слоям; null, если это не Lottie с массивом слоёв. */
export function inspectAnimations(lottie: Lottie): string | null {
  if (!isDict(lottie)) return null;
  const layers = asDictArray(lottie.layers);
  if (!layers) return null;

  const fps = intValue(lottie.fr) ?? 30;
  const op = intValue(lottie.op) ?? 0;

  const lines: string[] = [];
  lines.push(`Composition: ${fps}fps, ${op} frames (${formatFixed(op / fps, 1)}s)`);

  const channels: [string, string][] = [
    ["o", "opacity"], ["p", "position"], ["s", "scale"], ["r", "rotation"], ["rx", "rotationX"], ["ry", "rotationY"],
  ];

  for (const layer of layers) {
    const name = asString(layer.nm);
    if (name === null) continue;
    const ks: Dict = isDict(layer.ks) ? layer.ks : {};

    const animated: string[] = [];
    for (const [key, label] of channels) {
      const ch = ks[key];
      if (!isDict(ch) || asInt(ch.a) !== 1) continue;
      const kfs = asDictArray(ch.k);
      if (!kfs) continue;
      const times = kfs.map((f) => asInt(f.t)).filter((n): n is number => n !== null);
      if (times.length === 0) continue;
      const values = kfs
        .map((f) => (Array.isArray(f.s) ? asNumber(f.s[0]) : null))
        .filter((n): n is number => n !== null);
      const valStr = values.length === 0 ? "" : ` [${values.map((v) => formatFixed(v, 0)).join("→")}]`;
      animated.push(`${label} ${times[0]}→${times[times.length - 1]}f${valStr}`);
    }

    const ef = asDictArray(layer.ef);
    if (ef && ef.length > 0) {
      const names = ef.map((e) => asString(e.nm)).filter((n): n is string => n !== null);
      animated.push(`effects: ${names.join(", ")}`);
    }

    const shapes = asDictArray(layer.shapes);
    if (shapes) {
      if (hasAnimatedProperty(shapes, ["fl", "st"], "c")) animated.push("animated color");
      if (containsTrimPath(shapes)) animated.push("trim path");
    }

    lines.push(animated.length === 0 ? `  ${name}: static` : `  ${name}: ${animated.join(", ")}`);
  }
  return lines.join("\n");
}
