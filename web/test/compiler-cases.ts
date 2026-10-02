// Набор входов и spec-ов для golden-сравнения TS-компилятора со Swift (lottie-mcp).
// Используется и генератором фикстур (gen-compiler-fixtures.ts), и тестом (compiler.golden.test.ts).

import { join } from "node:path";

export const repoRoot = join(import.meta.dir, "..", "..");
export const fixturesDir = join(import.meta.dir, "fixtures", "compiler");

/** Ключ входа → путь к статичному Lottie. */
export const inputs: Record<string, string> = {
  rocket: join(repoRoot, "Sources/Resources/rocket_static_simplified.json"),
  demo: join(repoRoot, "Sources/Resources/demo_animation.json"),
  minimal: join(fixturesDir, "inputs/minimal.json"),
  items: join(fixturesDir, "inputs/items.json"),
  op1: join(fixturesDir, "inputs/op1.json"),
  shapes: join(fixturesDir, "inputs/shapes.json"),
  nowh: join(fixturesDir, "inputs/nowh.json"),
};

// MARK: - Synthetic inputs

function minimalLayer(name: string, ind: number): Record<string, any> {
  return {
    ty: 4, nm: name, ind, ip: 0, op: 60,
    ks: {
      o: { a: 0, k: 100, ix: 11 },
      p: { a: 0, k: [50, 50, 0], ix: 2 },
      s: { a: 0, k: [100, 100, 100], ix: 6 },
      r: { a: 0, k: 0, ix: 10 },
      a: { a: 0, k: [0, 0, 0], ix: 1 },
    },
    shapes: [{
      ty: "gr",
      it: [
        { ty: "sh", ks: { a: 0, k: { v: [[0, -10], [10, 0], [0, 10], [-10, 0]], i: [[0, 0], [0, 0], [0, 0], [0, 0]], o: [[0, 0], [0, 0], [0, 0], [0, 0]], c: true } } },
        { ty: "fl", c: { a: 0, k: [0.08, 0.53, 0.39, 1] }, o: { a: 0, k: 100 }, nm: "Fill" },
        { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } },
      ],
      nm: "Group",
    }],
  };
}

/** Как minimalLottie() из Tests/LottieCompilerTests.swift. */
export function minimalLottie(names: string[] = ["test"]): Record<string, any> {
  return { v: "5.7.1", fr: 30, ip: 0, op: 60, w: 100, h: 100, layers: names.map((n, i) => minimalLayer(n, i)) };
}

const tr = { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } };
const path = (v: number[][]) => ({ ty: "sh", ks: { a: 0, k: { v, i: v.map(() => [0, 0]), o: v.map(() => [0, 0]), c: true } }, nm: "Path" });
const stroke = (c = [1, 0, 0, 1]) => ({ ty: "st", c: { a: 0, k: c }, o: { a: 0, k: 100 }, w: { a: 0, k: 3 }, lc: 2, lj: 2, nm: "Stroke" });
const fill = (c = [0, 0, 1, 1]) => ({ ty: "fl", c: { a: 0, k: c }, o: { a: 0, k: 100 }, nm: "Fill" });

/** Слои с разными формами: штрихи в группах, вложенные группы, две фигуры, без shapes, анимации и т.д. */
export function shapesLottie(): Record<string, any> {
  const ks = (p: any = [100, 80, 0]) => ({
    o: { a: 0, k: 100, ix: 11 }, p: { a: 0, k: p, ix: 2 }, s: { a: 0, k: [100, 100, 100], ix: 6 },
    r: { a: 0, k: 15, ix: 10 }, a: { a: 0, k: [0, 0, 0], ix: 1 },
  });
  return {
    v: "5.7.1", fr: 60, ip: 0, op: 90, w: 300, h: 200,
    layers: [
      { ty: 4, nm: "stroked", ind: 3, ip: 0, op: 90, ks: ks(), shapes: [
        { ty: "gr", it: [path([[0, 0], [40, 0]]), stroke(), tr], nm: "G1" },
        { ty: "gr", it: [path([[0, 10], [40, 10]]), stroke(), fill()], nm: "G2 (no tr)" },
        { ty: "gr", it: [path([[0, 20], [40, 20]]), fill(), tr], nm: "G3 (fill only)" },
      ] },
      { ty: 4, nm: "nested", ind: 4, ip: 0, op: 90, ks: ks([10, 10, 0]), shapes: [
        { ty: "gr", it: [
          { ty: "gr", it: [path([[0, 0], [5, 5]]), stroke([0, 1, 0, 1]), tr], nm: "Inner" },
          { ty: "gr", it: [{ ty: "gr", it: [path([[1, 1], [2, 2]]), stroke(), tr], nm: "Deep" }, tr], nm: "Inner2" },
          stroke(), tr,
        ], nm: "Outer" },
        stroke([0.5, 0.5, 0.5, 1]),
      ] },
      { ty: 4, nm: "twoPaths", ind: 5, ip: 0, op: 90, ks: ks([150, 100, 0]), shapes: [
        { ty: "gr", it: [path([[0, -50], [50, 0], [0, 50], [-50, 0]]), fill([1, 1, 0, 1]), tr], nm: "Outer" },
        { ty: "gr", it: [{ ty: "gr", it: [path([[30, -20], [20, 20], [-20, 20], [-20, -20]]), fill(), tr], nm: "Inner" }, tr], nm: "Wrap" },
      ] },
      { ty: 4, nm: "ellipseOnly", ind: 6, ip: 0, op: 90, ks: ks(), shapes: [
        { ty: "gr", it: [{ ty: "el", p: { a: 0, k: [0, 0] }, s: { a: 0, k: [20, 20] } }, fill(), tr], nm: "E" },
      ] },
      { ty: 3, nm: "null", ind: 7, ip: 0, op: 90, ks: ks() },
      { ty: 4, nm: "noKs", ip: 0, op: 45, shapes: [{ ty: "gr", it: [path([[0, 0], [9, 3], [4, 8]]), fill(), tr] }] },
      { ty: 4, nm: "animated", ind: 2.5, ip: 0, op: 90, ks: {
        o: { a: 1, k: [
          { t: 0, s: [0], o: { x: [0.3], y: [0] }, i: { x: [0.7], y: [1] } },
          { t: 12.5, s: [100], o: { x: [0.3], y: [0] }, i: { x: [0.7], y: [1] } },
          { t: 40, s: [50], o: { x: [0.3], y: [0] }, i: { x: [0.7], y: [1] } },
          { t: 80, s: [100] },
        ], ix: 11 },
        p: { a: 0, k: [20, 30], ix: 22 },
        r: { a: 0, k: [7], ix: 10 },
        s: { a: 1, k: [{ t: 10, s: [100, 100, 100], o: { x: [0.3], y: [0] }, i: { x: [0.7], y: [1] } }, { t: 50, s: [120, 120, 100] }], ix: 6 },
      }, ef: [{ ty: 5, nm: "Existing Effect", ef: [] }], shapes: [
        { ty: "gr", it: [path([[0, 0], [10, 0], [10, 10]]),
          { ty: "fl", c: { a: 1, k: [{ t: 0, s: [1, 0, 0, 1] }, { t: 10, s: [0, 1, 0, 1] }] }, o: { a: 0, k: 100 } },
          { ty: "st", c: { a: 0, k: [0.2, 0.4, 0.6] }, o: { a: 0, k: 100 }, w: { a: 0, k: 1 } },
          {},
          tr], nm: "G" },
      ] },
      { ty: 4, nm: "star_a", ind: 8, ip: 0, op: 90, ks: ks([60, 60, 0]), shapes: [{ ty: "gr", it: [path([[0, 0], [1, 1]]), fill(), tr] }] },
      { ty: 4, nm: "b_star", ind: 9, ip: 5, op: 30, ks: ks([70, 60, 0]), shapes: [{ ty: "gr", it: [path([[0, 0], [1, 1]]), fill(), tr] }] },
      { ty: 4, nm: "dup", ind: 10, ip: 0, op: 90, ks: ks([1, 1, 0]), shapes: [] },
      { ty: 4, nm: "dup", ind: 11, ip: 0, op: 90, ks: ks([2, 2, 0]), shapes: [] },
      { ty: 4, nm: "topStroke", ind: 12, ip: 0, op: 120, ks: ks(), shapes: [path([[0, 0], [3, 4]]), stroke()] },
      { ty: 4, nm: "noGroups", ind: 13, ip: 0, op: 90, ks: ks(), shapes: [path([[0, 0], [3, 4]]), fill()] },
      { ty: 4, ind: 14, ip: 0, op: 90, ks: ks() },
    ],
  };
}

export function op1Lottie(): Record<string, any> {
  const root = minimalLottie(["a", "b", "c"]);
  root.op = 1;
  root.layers[0].op = 1;
  root.layers[1].op = 1;
  root.layers[2].op = 0.5;
  return root;
}

export function nowhLottie(): Record<string, any> {
  const root = minimalLottie(["test", "second"]);
  delete root.w;
  delete root.h;
  delete root.op;
  return root;
}

export const syntheticInputs: Record<string, () => Record<string, any>> = {
  minimal: () => minimalLottie(),
  items: () => minimalLottie(["item_1", "item_2", "item_3", "other"]),
  op1: op1Lottie,
  shapes: shapesLottie,
  nowh: nowhLottie,
};

// MARK: - Cases

export interface GoldenCase { name: string; input: string; spec: any }

const prim = (kind: string, start: number, end: number, easing: string, params?: any) =>
  params === undefined ? { kind, start, end, easing } : { kind, start, end, easing, params };

const one = (name: string, input: string, target: string, animations: any[], extra: any = {}): GoldenCase => ({
  name, input, spec: { fps: 30, durationFrames: 60, layers: [{ target, animations }], ...extra },
});

export const cases: GoldenCase[] = [
  // --- Every MotionKind (minimal), covering every easing
  one("fadeIn-easeOut", "minimal", "test", [prim("fadeIn", 0, 0.5, "easeOut")]),
  one("fadeOut-easeIn", "minimal", "test", [prim("fadeOut", 0.2, 0.7, "easeIn")]),
  one("slideIn-default", "minimal", "test", [prim("slideIn", 0, 0.5, "easeOutBack")]),
  one("slideIn-directions", "minimal", "test", [
    prim("slideIn", 0, 0.3, "linear", { direction: "up", distance: 40 }),
    prim("slideIn", 0.3, 0.6, "linear", { direction: "down", distance: 40 }),
    prim("slideIn", 0.6, 0.9, "linear", { direction: "left" }),
    prim("slideIn", 0.9, 1.2, "linear", { direction: "right", distance: 12.5 }),
    prim("slideIn", 1.2, 1.5, "linear", { direction: "diagonal" }),
  ]),
  one("slideOut", "minimal", "test", [prim("slideOut", 1, 1.6, "easeInBack", { direction: "left", distance: 200 })]),
  one("scaleIn-normalized", "minimal", "test", [prim("scaleIn", 0, 0.4, "easeInOutBack", { from: 0.5, to: 1 })]),
  one("scaleIn-default", "minimal", "test", [prim("scaleIn", 0, 0.4, "spring")]),
  one("scaleOut", "minimal", "test", [prim("scaleOut", 0.5, 1, "anticipate")]),
  one("scaleOut-params", "minimal", "test", [prim("scaleOut", 0.5, 1, "easeIn", { from: 120, to: 10 })]),
  one("rotate-default", "minimal", "test", [prim("rotate", 0, 1, "elastic")]),
  one("rotate-params", "minimal", "test", [prim("rotate", 0, 1, "linear", { fromDeg: -10, toDeg: 90 })]),
  one("pulse", "minimal", "test", [prim("pulse", 0, 1, "spring", { amount: 120 })]),
  one("pulse-repeat-normalized", "minimal", "test", [prim("pulse", 0.1, 1.9, "easeInOut", { amount: 1.2, repeatCount: 3 })]),
  one("pulse-tiny-span", "minimal", "test", [prim("pulse", 0, 0.05, "easeOut", { repeatCount: 5 })]),
  one("bounce", "minimal", "test", [prim("bounce", 0, 0.5, "easeOut", { amount: 20 })]),
  one("bounce-default", "minimal", "test", [prim("bounce", 0.3, 1.3, "linear")]),
  one("drawOn-fill-single-path", "minimal", "test", [prim("drawOn", 0, 1, "easeInOut")]),
  one("wiggle-default", "minimal", "test", [prim("wiggle", 0, 1, "linear")]),
  one("wiggle-params", "minimal", "test", [prim("wiggle", 0.2, 1.4, "linear", { amount: 7.5, frequency: 2.5 })]),
  one("wiggle-tiny-span", "minimal", "test", [prim("wiggle", 0, 0.1, "linear", { frequency: 6 })]),
  one("wiggle-low-frequency", "minimal", "test", [prim("wiggle", 0, 1, "linear", { frequency: 0.2 })]),
  one("spin", "minimal", "test", [prim("spin", 0, 2, "easeInOut", { repeatCount: 2 })]),
  one("spin-default", "minimal", "test", [prim("spin", 0, 1, "spring")]),
  one("float", "minimal", "test", [prim("float", 0, 2, "linear")]),
  one("float-amount", "minimal", "test", [prim("float", 0, 1, "linear", { amount: 4 })]),
  one("breathe", "minimal", "test", [prim("breathe", 0, 2, "linear", { repeatCount: 2 })]),
  one("breathe-amount", "minimal", "test", [prim("breathe", 0, 1, "easeOutBack", { amount: 1.03 })]),
  one("swing", "minimal", "test", [prim("swing", 0, 1, "linear")]),
  one("swing-amount", "minimal", "test", [prim("swing", 0, 0.1, "linear", { amount: 25 })]),
  one("followPath", "minimal", "test", [prim("followPath", 0, 1, "easeInOut", { path: [[0, 0], [30, -20], [60, 0]] })]),
  one("followPath-short-points", "minimal", "test", [prim("followPath", 0, 0.05, "easeOut", { path: [[5], [], [1, 2, 3], [4, 4]] })]),
  one("followPath-missing", "minimal", "test", [
    prim("followPath", 0, 1, "linear", { path: [[1, 1]] }),
    prim("followPath", 0, 1, "linear"),
  ]),
  one("recolor", "minimal", "test", [prim("recolor", 0, 0, "linear", { color: "#F0A" })]),
  one("recolor-invalid", "minimal", "test", [
    prim("recolor", 0, 0, "linear", { color: "#XYZXYZ" }),
    prim("recolor", 0, 0, "linear"),
    prim("recolor", 0, 0, "linear", { color: "12345" }),
  ]),
  one("recolor-sign-hex", "minimal", "test", [prim("recolor", 0, 0, "linear", { color: "#+1A2B3" })]),
  one("squash", "minimal", "test", [prim("squash", 0, 0.5, "easeInOut", { amount: 130 })]),
  one("squash-normalized", "minimal", "test", [prim("squash", 0, 0.5, "easeOut", { amount: 1.5 })]),
  one("stretch", "minimal", "test", [prim("stretch", 0, 0.5, "easeInOut")]),
  one("flash", "minimal", "test", [prim("flash", 0, 0.5, "linear", { amount: 0, repeatCount: 2 })]),
  one("flash-default", "minimal", "test", [prim("flash", 0.5, 1.5, "easeIn", { amount: 30 })]),
  one("flip-y", "minimal", "test", [prim("flip", 0, 0.5, "easeInOut", { fromDeg: 0, toDeg: 180 })]),
  one("flip-x", "minimal", "test", [prim("flip", 0, 0.5, "easeInOut", { axis: "x" })]),
  one("colorTransition-from", "minimal", "test", [prim("colorTransition", 0, 1, "easeInOut", { color: "#FF0000", fromColor: "#00FF00" })]),
  one("colorTransition-current", "minimal", "test", [prim("colorTransition", 0, 1, "linear", { color: "#123" })]),
  one("colorTransition-missing", "minimal", "test", [prim("colorTransition", 0, 1, "linear", { fromColor: "#123" })]),
  one("blurIn", "minimal", "test", [prim("blurIn", 0, 0.5, "easeOut", { blurAmount: 25 })]),
  one("blurOut-default", "minimal", "test", [prim("blurOut", 0, 0.5, "easeIn")]),
  one("blur-both", "minimal", "test", [prim("blurIn", 0, 0.5, "easeOut"), prim("blurOut", 1, 1.5, "easeIn", { blurAmount: 5 })]),
  one("removeFill", "minimal", "test", [prim("removeFill", 0, 0, "linear")]),
  one("removeStroke", "minimal", "test", [prim("removeStroke", 0, 0, "linear")]),
  one("addStroke", "minimal", "test", [prim("removeFill", 0, 0, "linear"), prim("addStroke", 0, 0, "linear", { color: "#FF0000", strokeWidth: 4 })]),
  one("addStroke-default", "minimal", "test", [prim("addStroke", 0, 0, "linear")]),
  one("addFill", "minimal", "test", [prim("addFill", 0, 0, "linear", { color: "#0f0" })]),
  one("addFill-invalid", "minimal", "test", [prim("addFill", 0, 0, "linear", { color: "nope" })]),
  one("hideLayer", "minimal", "test", [prim("hideLayer", 0, 0, "linear")]),
  one("showLayer", "minimal", "test", [prim("hideLayer", 0, 0, "linear"), prim("showLayer", 0, 0, "linear")]),

  // --- Timing / clamping / merge
  one("zero-and-negative-duration", "minimal", "test", [
    prim("fadeIn", 0.5, 0.5, "linear"),
    prim("rotate", -1, -2, "linear"),
    prim("scaleIn", 1.2, 0.3, "linear"),
  ]),
  one("half-frame-rounding", "minimal", "test", [prim("fadeIn", 0.25, 0.35, "linear"), prim("rotate", 1 / 60, 0.05, "linear")]),
  { name: "fps-clamp-high", input: "minimal", spec: { fps: 1000, durationFrames: 30, layers: [] } },
  { name: "fps-clamp-low", input: "minimal", spec: { fps: 10, durationFrames: 0, layers: [{ target: "test", animations: [prim("fadeIn", 0, 1, "linear")] }] } },
  { name: "duration-clamp", input: "minimal", spec: { fps: 60, durationFrames: 10000, layers: [{ target: "test", animations: [prim("spin", 0, 12, "linear")] }] } },
  one("merge-fade-in-out", "minimal", "test", [prim("fadeIn", 0, 0.5, "easeOut"), prim("fadeOut", 1, 1.5, "easeIn")]),
  one("merge-earlier-replaces", "minimal", "test", [prim("fadeOut", 1, 1.5, "easeIn"), prim("fadeIn", 0, 0.5, "easeOut")]),
  one("merge-three-scale", "minimal", "test", [
    prim("scaleIn", 0, 0.3, "easeOut"), prim("pulse", 0.5, 1, "spring"), prim("scaleOut", 1.5, 1.9, "easeIn"),
  ]),
  one("multiple-channels", "minimal", "test", [
    prim("fadeIn", 0, 0.5, "easeOut"),
    prim("scaleIn", 0, 0.5, "spring", { from: 0, to: 100 }),
    prim("rotate", 0, 0.5, "linear", { fromDeg: -10, toDeg: 0 }),
  ]),
  one("missing-layer", "minimal", "nonexistent", [prim("fadeIn", 0, 0.5, "linear")]),

  // --- Wildcards / stagger
  one("wildcard-stagger", "items", "item_*", [prim("fadeIn", 0, 0.5, "easeOut")]),
  { name: "wildcard-stagger-0.1", input: "items", spec: { fps: 30, durationFrames: 30, layers: [{ target: "item_*", animations: [prim("fadeIn", 0, 0.5, "easeOut")], staggerDelay: 0.1 }] } },
  { name: "wildcard-stagger-slide", input: "items", spec: { fps: 60, durationFrames: 120, layers: [{ target: "item_*", animations: [prim("slideIn", 0.1, 0.6, "easeOutBack", { direction: "left", distance: 30 }), prim("drawOn", 0, 1, "linear")], staggerDelay: 0.07 }] } },
  { name: "wildcard-negative-stagger", input: "items", spec: { fps: 30, durationFrames: 60, layers: [{ target: "item_*", animations: [prim("fadeIn", 0.5, 1, "linear")], staggerDelay: -0.2 }] } },
  one("wildcard-suffix", "items", "*_2", [prim("spin", 0, 1, "linear")]),
  one("wildcard-all", "items", "*", [prim("fadeIn", 0, 1, "linear")]),
  one("wildcard-middle-no-match", "items", "item*1", [prim("fadeIn", 0, 1, "linear")]),
  one("wildcard-prefix-no-match", "items", "zzz*", [prim("fadeIn", 0, 1, "linear")]),

  // --- Generated layers
  {
    name: "generated-rings", input: "minimal", spec: {
      fps: 30, durationFrames: 15,
      generatedLayers: [
        { name: "wave1", shape: "ellipse", anchor: "test", width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 3, opacity: 0 },
        { name: "wave2", shape: "ellipse", anchor: "test", width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 2, opacity: 0 },
      ],
      layers: [
        { target: "test", animations: [prim("pulse", 0, 0.35, "anticipate", { amount: 112 })] },
        { target: "wave1", animations: [prim("fadeIn", 0.08, 0.18, "easeOut"), prim("scaleIn", 0.08, 0.38, "easeOut", { from: 60, to: 100 }), prim("fadeOut", 0.28, 0.38, "easeIn")] },
        { target: "wave2", animations: [prim("fadeIn", 0.14, 0.24, "easeOut"), prim("scaleIn", 0.14, 0.42, "easeOut", { from: 50, to: 100 }), prim("fadeOut", 0.32, 0.42, "easeIn")] },
      ],
    },
  },
  {
    name: "generated-shapes-and-warnings", input: "shapes", spec: {
      fps: 60, durationFrames: 120,
      generatedLayers: [
        { name: "rect", shape: "rectangle", anchor: "stroked", width: 40, fillColor: "#336699" },
        { name: "plain", shape: "ellipse", anchor: "noKs" },
        { name: "both", shape: "rectangle", anchor: "animated", height: 12.5, fillColor: "#abc", strokeColor: "#000", opacity: 55 },
        { name: "badHex", shape: "ellipse", anchor: "stroked", fillColor: "#GG0000" },
        { name: "stroked", shape: "ellipse", anchor: "nested" },
        { name: "orphan", shape: "ellipse", anchor: "nonexistent" },
        { name: "twin", shape: "ellipse", anchor: "dup" },
        { name: "twin", shape: "rectangle", anchor: "null" },
      ],
      layers: [
        { target: "rect", animations: [prim("slideIn", 0, 0.5, "easeOut")] },
        { target: "twin", animations: [prim("fadeIn", 0, 0.5, "easeOut")] },
        { target: "plain", animations: [prim("drawOn", 0, 0.5, "easeOut")] },
        { target: "both", animations: [prim("drawOn", 0, 0.5, "easeOut"), prim("recolor", 0, 0, "linear", { color: "#ff00ff" })] },
      ],
    },
  },
  {
    name: "generated-on-rocket", input: "rocket", spec: {
      fps: 60, durationFrames: 120,
      generatedLayers: [{ name: "halo", shape: "ellipse", anchor: "Body ctrl P", width: 300, height: 300, fillColor: "#FFD700", opacity: 0 }],
      layers: [
        { target: "halo", animations: [prim("fadeIn", 0, 0.3, "easeOut"), prim("breathe", 0.3, 2, "easeInOut", { repeatCount: 2 }), prim("fadeOut", 1.6, 2, "easeIn")] },
        { target: "Body ctrl P", animations: [prim("float", 0, 2, "easeInOut", { amount: 20 })] },
      ],
    },
  },

  // --- drawOn: trim injection, mattes
  one("drawOn-strokes", "shapes", "stroked", [prim("drawOn", 0, 1, "easeInOut")]),
  one("drawOn-nested", "shapes", "nested", [prim("drawOn", 0.2, 0.8, "easeOut")]),
  one("drawOn-two-paths-matte", "shapes", "twoPaths", [prim("drawOn", 0, 1, "easeInOut")]),
  one("drawOn-no-paths", "shapes", "ellipseOnly", [prim("drawOn", 0, 1, "linear")]),
  one("drawOn-null-layer", "shapes", "null", [prim("drawOn", 0, 1, "linear")]),
  one("drawOn-noKs", "shapes", "noKs", [prim("drawOn", 0, 1, "linear")]),
  one("drawOn-top-level-stroke", "shapes", "topStroke", [prim("drawOn", 0, 1, "linear")]),
  one("drawOn-no-groups-fill", "shapes", "noGroups", [prim("drawOn", 0, 1, "linear")]),
  one("drawOn-twice-fill", "shapes", "twoPaths", [prim("drawOn", 0, 0.5, "linear"), prim("drawOn", 0.5, 1, "easeIn")]),
  one("drawOn-plus-slide-same-spec", "shapes", "twoPaths", [prim("slideIn", 0, 0.5, "easeOut"), prim("drawOn", 0, 1, "linear")]),
  {
    name: "drawOn-after-clip-separate-specs", input: "shapes", spec: {
      fps: 60, durationFrames: 90, layers: [
        { target: "twoPaths", animations: [prim("slideIn", 0, 0.5, "easeOut")] },
        { target: "twoPaths", animations: [prim("drawOn", 0, 1, "linear")] },
        { target: "twoPaths", animations: [prim("slideOut", 1, 1.4, "easeIn")] },
      ],
    },
  },
  one("drawOn-rocket-body", "rocket", "Body", [prim("drawOn", 0, 1.5, "easeInOut")]),
  {
    name: "drawOn-rocket-wildcard", input: "rocket", spec: {
      fps: 60, durationFrames: 180, layers: [{ target: "Body*", animations: [prim("drawOn", 0, 1, "easeOut")], staggerDelay: 0.1 }],
    },
  },

  // --- Clip mattes
  one("clip-single", "minimal", "test", [prim("slideIn", 0, 0.5, "easeOut", { direction: "right" })]),
  {
    name: "clip-multiple-layers", input: "items", spec: {
      fps: 30, durationFrames: 60, layers: [
        { target: "item_3", animations: [prim("slideIn", 0, 0.5, "easeOut")] },
        { target: "item_1", animations: [prim("slideOut", 0, 0.5, "easeOut")] },
        { target: "item_1", animations: [prim("slideIn", 1, 1.5, "easeOut")] },
        { target: "other", animations: [prim("drawOn", 0, 1, "linear")] },
      ],
    },
  },
  one("clip-default-comp-size", "nowh", "test", [prim("slideIn", 0, 0.5, "easeOut")]),
  {
    name: "nowh-op-fix", input: "nowh", spec: { fps: 30, durationFrames: 90, layers: [{ target: "second", animations: [prim("fadeIn", 0, 1, "linear")] }] },
  },

  // --- Shapes layer edge cases
  {
    name: "shapes-edits", input: "shapes", spec: {
      fps: 60, durationFrames: 120, layers: [
        { target: "nested", animations: [prim("removeStroke", 0, 0, "linear"), prim("addFill", 0, 0, "linear", { color: "#ABCDEF" })] },
        { target: "stroked", animations: [prim("removeFill", 0, 0, "linear"), prim("recolor", 0, 0, "linear", { color: "#010203" })] },
        { target: "animated", animations: [prim("removeFill", 0, 0, "linear")] },
        { target: "noGroups", animations: [prim("addStroke", 0, 0, "linear", { strokeWidth: 0.5 })] },
        { target: "null", animations: [prim("addFill", 0, 0, "linear"), prim("removeFill", 0, 0, "linear"), prim("recolor", 0, 0, "linear", { color: "#fff" }), prim("colorTransition", 0, 1, "linear", { color: "#fff" })] },
      ],
    },
  },
  {
    name: "shapes-animated-base", input: "shapes", spec: {
      fps: 60, durationFrames: 120, layers: [
        { target: "animated", animations: [
          prim("fadeOut", 0.5, 1, "easeIn"),
          prim("slideIn", 0, 0.5, "easeOut"),
          prim("rotate", 0, 1, "linear"),
          prim("pulse", 0.4, 1, "spring"),
          prim("colorTransition", 0, 1, "linear", { color: "#00ff00" }),
          prim("blurIn", 0, 0.3, "easeOut"),
          prim("flip", 0, 1, "linear", { axis: "y", fromDeg: 10 }),
        ] },
        { target: "noKs", animations: [prim("swing", 0, 1, "linear"), prim("bounce", 0, 1, "linear"), prim("flip", 0, 1, "linear", { axis: "x" })] },
        { target: "dup", animations: [prim("wiggle", 0, 1, "linear")] },
        { target: "star_a", animations: [prim("spin", 0, 1, "linear")] },
      ],
    },
  },
  one("shapes-suffix-wildcard", "shapes", "*star", [prim("fadeIn", 0, 0.2, "linear")]),
  one("shapes-prefix-wildcard", "shapes", "star*", [prim("fadeIn", 0, 0.2, "linear")]),

  // --- Unanimated layers op fix
  { name: "op1-unanimated-live", input: "op1", spec: { fps: 60, durationFrames: 120, layers: [{ target: "a", animations: [prim("fadeIn", 0, 0.5, "easeOut")] }] } },
  { name: "rocket-typical", input: "rocket", spec: {
    fps: 60, durationFrames: 180, layers: [
      { target: "Body ctrl P", animations: [prim("slideIn", 0, 0.6, "easeOutBack", { direction: "up", distance: 400 }), prim("float", 0.6, 3, "easeInOut")] },
      { target: "1 wing", animations: [prim("rotate", 0.2, 0.8, "spring", { fromDeg: -30, toDeg: 0 })] },
      { target: "2 wing", animations: [prim("rotate", 0.2, 0.8, "spring", { fromDeg: 30, toDeg: 0 })] },
      { target: "Iilum*", animations: [prim("flash", 0.5, 2.5, "linear", { repeatCount: 4, amount: 40 })], staggerDelay: 0.25 },
    ],
  } },

  // --- Modify mode on demo_animation (existing keyframes, fractional t, op fix with op ≠ integer)
  { name: "demo-modify", input: "demo", spec: {
    fps: 60, durationFrames: 120, layers: [
      { target: "Iilum", animations: [prim("slideIn", 0.5, 1, "easeOut")] },
      { target: "Body ctrl P", animations: [prim("rotate", 0.5, 1.5, "easeInOut", { toDeg: 0 }), prim("bounce", 1, 1.5, "easeOut")] },
      { target: "Circle star 1", animations: [prim("recolor", 0, 0, "linear", { color: "#FF8800" })] },
      { target: "Circle star 2", animations: [prim("colorTransition", 0, 1, "linear", { color: "#00FFAA" })] },
      { target: "Soplo Line 1", animations: [prim("drawOn", 0, 0.5, "easeOut")] },
      { target: "Cross star *", animations: [prim("spin", 0, 2, "linear")], staggerDelay: 0.1 },
    ],
  } },
  { name: "demo-shorter", input: "demo", spec: { fps: 60, durationFrames: 60, layers: [{ target: "Soplo Line *", animations: [prim("fadeOut", 0.5, 0.9, "easeIn")], staggerDelay: 0.02 }] } },
  { name: "demo-longer", input: "demo", spec: { fps: 30, durationFrames: 240, layers: [{ target: "Body", animations: [prim("pulse", 0, 4, "easeInOut", { repeatCount: 4 })] }, { target: "Iilum 2", animations: [prim("fadeIn", 0, 0.2, "linear"), prim("slideOut", 2, 3, "easeIn")] }] } },
  { name: "demo-no-layers", input: "demo", spec: { fps: 60, durationFrames: 120, layers: [] } },
];

// MARK: - Spec parsing error cases (Swift JSONDecoder messages)

const A = { kind: "fadeIn", start: 0, end: 1, easing: "linear" };
const withPrim = (p: any) => ({ fps: 30, durationFrames: 30, layers: [{ target: "a", animations: [p] }] });
const withParams = (params: any) => withPrim({ ...A, params });

export const specErrorCases: any[] = [
  {}, [], "x", "[1]", "{bad json",
  { fps: 30.5, durationFrames: 30, layers: [] },
  { fps: "30", durationFrames: 30, layers: [] },
  { fps: null, durationFrames: 30, layers: [] },
  { fps: true, durationFrames: 30, layers: [] },
  { fps: [1], durationFrames: 30, layers: [] },
  { fps: {}, durationFrames: 30, layers: [] },
  { fps: 30, layers: [] },
  { fps: 30, durationFrames: 30 },
  { fps: 30, durationFrames: 30, layers: {} },
  { fps: 30, durationFrames: 30, layers: null },
  { fps: 30, durationFrames: 30, layers: [1] },
  { fps: 30, durationFrames: 30, layers: [null] },
  { fps: 30, durationFrames: 30, layers: [{ animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: "a" }] },
  { fps: 30, durationFrames: 30, layers: [{ target: 5, animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: true, animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: null, animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: [], animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: {}, animations: [] }] },
  { fps: 30, durationFrames: 30, layers: [{ target: "a", animations: [], staggerDelay: "1" }] },
  withPrim({ ...A, start: "0" }),
  withPrim({ ...A, start: true }),
  withPrim({ ...A, kind: 5 }),
  withPrim({ ...A, kind: null }),
  withPrim({ ...A, kind: "explode" }),
  withPrim({ ...A, easing: "bogus" }),
  withPrim({ kind: "fadeIn", start: 0, end: 1 }),
  withPrim({ kind: "fadeIn", end: 1, easing: "linear" }),
  withPrim({ start: 0, end: 1 }),
  withParams("x"),
  withParams({ repeatCount: 2.5 }),
  withParams({ repeatCount: "2" }),
  withParams({ path: [[1, "a"]] }),
  withParams({ path: [1] }),
  withParams({ path: [[1, null]] }),
  withParams({ path: [null] }),
  withParams({ path: {} }),
  withParams({ from: [1] }),
  withParams({ from: {} }),
  withParams({ color: 7 }),
  withParams({ axis: false }),
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: [{ name: "g", shape: "star", anchor: "a" }] },
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: [{ name: "g", anchor: "a" }] },
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: [{ shape: "ellipse", anchor: "a" }] },
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: [{ name: "g", shape: "ellipse", anchor: "a", width: "1" }] },
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: {} },
  { fps: 30, durationFrames: 30, layers: [], generatedLayers: [null] },
  { fps: 1e20, durationFrames: 30, layers: [] },
];

/** Spec-и, которые должны успешно разобраться (null у опциональных, лишние ключи, большие Int). */
export const specOkCases: any[] = [
  { fps: 30, durationFrames: 30, layers: [{ target: "a", animations: [A], staggerDelay: null }], generatedLayers: null },
  withParams({ repeatCount: null, color: null, path: null }),
  { fps: -5, durationFrames: 3000000000, layers: [], extra: 1 },
  { fps: 30.0, durationFrames: 30, layers: [{ target: "a", animations: [{ ...A, junk: true }], other: [] }] },
  JSON.stringify({ fps: 60, durationFrames: 60, layers: [] }),
];

// MARK: - inspectAnimations edge inputs (сравниваются с get_geometry.animations из Swift)

const okf = (t: any, s: any[]) => ({ t, s });
export const inspectInputs: { name: string; lottie: any }[] = [
  { name: "tie-rounding", lottie: { fr: 60, op: 15, ip: 0, w: 10, h: 10, layers: [
    { ty: 4, nm: "vals", ks: {
      o: { a: 1, k: [okf(0, [2.5]), okf(5, [0.5]), okf(10, [-0.4]), okf(12, [1.5]), okf(14, [-2.5])] },
      r: { a: 1, k: [okf(0.5, [3.5]), okf(3, [99.5]), okf(7, [100.49999])] },
      s: { a: 1, k: [okf(0, [1e21, 1]), okf(9, [-0.0, 1])] },
      p: { a: 1, k: [{ t: 1.5, s: [1] }] },
      rx: { a: 1, k: [{ t: 4, s: "x" }, { t: 8 }] },
      ry: { a: 0, k: 5 },
    }, ef: [{ nm: "A" }, { ty: 1 }, { nm: "B" }], shapes: [
      { ty: "gr", it: [{ ty: "gr", it: [{ ty: "tm" }] }, { ty: "st", c: { a: 1, k: [] } }] },
    ] },
    { ty: 4, nm: "static" },
    { ty: 4, ks: { o: { a: 1, k: [okf(0, [0])] } } },
    { ty: 4, nm: "emptyEf", ef: [], shapes: [{ ty: "fl", c: { a: 0, k: [1, 1, 1] } }] },
    { ty: 4, nm: "true-a", ks: { o: { a: true, k: [okf(0, [0]), okf(2, [1])] } } },
  ] } },
  { name: "no-fr-op", lottie: { layers: [{ nm: "x", ks: {} }] } },
  { name: "fr-zero", lottie: { fr: 0, op: 15, layers: [] } },
  { name: "fr-zero-op-zero", lottie: { fr: 0, op: 0, layers: [] } },
  { name: "fractional-fr-op", lottie: { fr: 29.97, op: 100.9, layers: [{ nm: "a" }] } },
  { name: "negative", lottie: { fr: 30, op: -45, layers: [] } },
  { name: "bad-layers", lottie: { fr: 30, op: 30, layers: [1, 2] } },
];
