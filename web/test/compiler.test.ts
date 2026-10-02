// Порт Tests/LottieCompilerTests.swift.

import { describe, expect, test } from "bun:test";
import { compile } from "../src/core/compiler";
import { parseSpec, type AnimationSpec, type MotionPrimitive } from "../src/core/spec";
import { minimalLottie } from "./compiler-cases";

type Dict = Record<string, any>;

const prim = (kind: MotionPrimitive["kind"], start: number, end: number, easing: MotionPrimitive["easing"] = "easeInOut", params?: MotionPrimitive["params"]): MotionPrimitive =>
  params ? { kind, start, end, easing, params } : { kind, start, end, easing };

const spec = (layers: AnimationSpec["layers"], extra: Partial<AnimationSpec> = {}): AnimationSpec =>
  ({ fps: 30, durationFrames: 30, layers, ...extra });

const compiled = (s: AnimationSpec, layerNames: string[] = ["test"]): Dict => compile(minimalLottie(layerNames), s).lottie;
const nonMatte = (root: Dict): Dict[] => root.layers.filter((l: Dict) => l.td !== 1);
const layerKS = (root: Dict, index = 0): Dict => nonMatte(root)[index]!.ks;
const isAnimated = (ch: Dict) => ch.a === 1;

describe("LottieCompiler", () => {
  test("unanimated layers live for whole duration", () => {
    const root = minimalLottie(["a", "b"]);
    root.op = 1;
    for (const l of root.layers) l.op = 1;
    const out = compile(root, spec([{ target: "a", animations: [prim("fadeIn", 0, 0.5, "easeOut")] }], { fps: 60, durationFrames: 120 })).lottie;
    for (const layer of out.layers) expect(layer.op).toBe(120);
  });

  test("does not mutate input", () => {
    const root = minimalLottie();
    const before = JSON.stringify(root);
    compile(root, spec([{ target: "test", animations: [prim("slideIn", 0, 1), prim("recolor", 0, 0, "linear", { color: "#f00" }), prim("drawOn", 0, 1)] }]));
    expect(JSON.stringify(root)).toBe(before);
  });

  test("fadeIn", () => {
    const o = layerKS(compiled(spec([{ target: "test", animations: [prim("fadeIn", 0, 0.5, "easeOut")] }]))).o;
    expect(isAnimated(o)).toBe(true);
    expect(o.k.length).toBe(2);
    expect(o.k[0].s[0]).toBeCloseTo(0, 2);
    expect(o.k[1].s[0]).toBeCloseTo(100, 2);
  });

  test("fadeOut", () => {
    const o = layerKS(compiled(spec([{ target: "test", animations: [prim("fadeOut", 0, 0.5, "easeIn")] }]))).o;
    expect(o.k[0].s[0]).toBeCloseTo(100, 2);
    expect(o.k[1].s[0]).toBeCloseTo(0, 2);
  });

  test("pulse", () => {
    const s = layerKS(compiled(spec([{ target: "test", animations: [prim("pulse", 0, 1, "spring", { amount: 120 })] }]))).s;
    expect(isAnimated(s)).toBe(true);
    expect(s.k.length).toBeGreaterThanOrEqual(3);
    expect(s.k[0].s[0]).toBeCloseTo(100, 2);
    expect(s.k[1].s[0]).toBeCloseTo(120, 2);
  });

  test("bounce", () => {
    const p = layerKS(compiled(spec([{ target: "test", animations: [prim("bounce", 0, 0.5, "easeOut", { amount: 20 })] }]))).p;
    expect(isAnimated(p)).toBe(true);
    expect(p.k.length).toBe(3);
  });

  test("rotate", () => {
    const r = layerKS(compiled(spec([{ target: "test", animations: [prim("rotate", 0, 1, "linear", { fromDeg: 0, toDeg: 90 })] }]))).r;
    expect(r.k[0].s[0]).toBeCloseTo(0, 2);
    expect(r.k[1].s[0]).toBeCloseTo(90, 2);
  });

  test("squash", () => {
    const s = layerKS(compiled(spec([{ target: "test", animations: [prim("squash", 0, 0.5, "easeInOut", { amount: 130 })] }]))).s;
    expect(s.k.length).toBe(3);
    expect(s.k[1].s[0]).toBeCloseTo(130, 2);
    expect(s.k[1].s[1]).toBeCloseTo(10000 / 130, 2);
    expect(s.k[2].s[0]).toBeCloseTo(100, 2);
  });

  test("stretch", () => {
    const s = layerKS(compiled(spec([{ target: "test", animations: [prim("stretch", 0, 0.5, "easeInOut", { amount: 130 })] }]))).s;
    expect(s.k[1].s[0]).toBeCloseTo(10000 / 130, 2);
    expect(s.k[1].s[1]).toBeCloseTo(130, 2);
  });

  test("flash", () => {
    const o = layerKS(compiled(spec([{ target: "test", animations: [prim("flash", 0, 0.5, "linear", { amount: 0, repeatCount: 2 })] }]))).o;
    expect(o.k.length).toBeGreaterThanOrEqual(5);
    expect(o.k[0].s[0]).toBeCloseTo(100, 2);
    expect(o.k[1].s[0]).toBeCloseTo(0, 2);
  });

  test("flip", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("flip", 0, 0.5, "easeInOut", { fromDeg: 0, toDeg: 180 })] }])))[0]!;
    expect(layer.ddd).toBe(1);
    expect(layer.ks.ry.k[0].s[0]).toBeCloseTo(0, 2);
    expect(layer.ks.ry.k[1].s[0]).toBeCloseTo(180, 2);
  });

  test("flip X axis", () => {
    const ks = layerKS(compiled(spec([{ target: "test", animations: [prim("flip", 0, 0.5, "easeInOut", { axis: "x" })] }])));
    expect(ks.rx).toBeDefined();
    expect(ks.ry).toBeUndefined();
  });

  test("colorTransition", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("colorTransition", 0, 1, "easeInOut", { color: "#FF0000", fromColor: "#00FF00" })] }])))[0]!;
    const fill = layer.shapes[0].it.find((s: Dict) => s.ty === "fl");
    expect(isAnimated(fill.c)).toBe(true);
    expect(fill.c.k.length).toBe(2);
    expect(fill.c.k[0].s[1]).toBeCloseTo(1, 2);
    expect(fill.c.k[1].s[0]).toBeCloseTo(1, 2);
  });

  test("blurIn", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("blurIn", 0, 0.5, "easeOut", { blurAmount: 25 })] }])))[0]!;
    expect(layer.ef.length).toBe(1);
    expect(layer.ef[0].ty).toBe(29);
    const kfs = layer.ef[0].ef[0].v.k;
    expect(kfs[0].s[0]).toBeCloseTo(25, 2);
    expect(kfs[1].s[0]).toBeCloseTo(0, 2);
  });

  test("blurOut", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("blurOut", 0, 0.5, "easeIn", { blurAmount: 30 })] }])))[0]!;
    const kfs = layer.ef[0].ef[0].v.k;
    expect(kfs[0].s[0]).toBeCloseTo(0, 2);
    expect(kfs[1].s[0]).toBeCloseTo(30, 2);
  });

  test("elastic easing", () => {
    const s = layerKS(compiled(spec([{ target: "test", animations: [prim("scaleIn", 0, 0.5, "elastic", { from: 0, to: 100 })] }]))).s;
    expect(s.k[0].o.y[0]).toBeGreaterThan(0.8);
  });

  test("wildcard matching with stagger", () => {
    const root = compiled(spec([{ target: "item_*", animations: [prim("fadeIn", 0, 0.5, "easeOut")], staggerDelay: 0.1 }]), ["item_1", "item_2", "item_3", "other"]);
    const layers = nonMatte(root);
    for (let i = 0; i < 3; i++) {
      expect(isAnimated(layers[i]!.ks.o)).toBe(true);
      expect(layers[i]!.ks.o.k[0].t).toBe(i * 3);
    }
    expect(isAnimated(layers[3]!.ks.o)).toBe(false);
  });

  test("missing layer warning", () => {
    const r = compile(minimalLottie(), spec([{ target: "nonexistent", animations: [prim("fadeIn", 0, 0.5)] }]));
    expect(r.warnings.some((w) => w.includes("nonexistent"))).toBe(true);
  });

  test("multiple channels on same layer", () => {
    const ks = layerKS(compiled(spec([{
      target: "test",
      animations: [
        prim("fadeIn", 0, 0.5, "easeOut"),
        prim("scaleIn", 0, 0.5, "spring", { from: 0, to: 100 }),
        prim("rotate", 0, 0.5, "linear", { fromDeg: -10, toDeg: 0 }),
      ],
    }])));
    expect(isAnimated(ks.o)).toBe(true);
    expect(isAnimated(ks.s)).toBe(true);
    expect(isAnimated(ks.r)).toBe(true);
  });

  test("invalid static Lottie throws", () => {
    expect(() => compile("not json" as any, spec([]))).toThrow("Static Lottie JSON is not a valid object with layers");
    expect(() => compile({ layers: [1] }, spec([]))).toThrow();
    expect(() => compile({}, spec([]))).toThrow();
  });

  test("generated layer ring", () => {
    const root = compiled(spec([
      { target: "test", animations: [prim("pulse", 0, 0.35, "anticipate", { amount: 112 })] },
      { target: "wave1", animations: [prim("fadeIn", 0.08, 0.18, "easeOut"), prim("scaleIn", 0.08, 0.38, "easeOut", { from: 60, to: 100 }), prim("fadeOut", 0.28, 0.38, "easeIn")] },
      { target: "wave2", animations: [prim("fadeIn", 0.14, 0.24, "easeOut"), prim("scaleIn", 0.14, 0.42, "easeOut", { from: 50, to: 100 }), prim("fadeOut", 0.32, 0.42, "easeIn")] },
    ], {
      durationFrames: 15,
      generatedLayers: [
        { name: "wave1", shape: "ellipse", anchor: "test", width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 3, opacity: 0 },
        { name: "wave2", shape: "ellipse", anchor: "test", width: 80, height: 80, strokeColor: "#FFFFFF", strokeWidth: 2, opacity: 0 },
      ],
    }));
    const layers = nonMatte(root);
    expect(layers.map((l) => l.nm)).toEqual(["wave1", "wave2", "test"]);
    expect(isAnimated(layers[0]!.ks.o)).toBe(true);
    expect(isAnimated(layers[0]!.ks.s)).toBe(true);
    expect(layers[0]!.ks.p.k[0]).toBeCloseTo(50, 2);
    expect(layers[0]!.ks.p.k[1]).toBeCloseTo(50, 2);
    const items: Dict[] = layers[0]!.shapes[0].it;
    expect(items.some((s) => s.ty === "el")).toBe(true);
    expect(items.some((s) => s.ty === "st")).toBe(true);
    expect(items.some((s) => s.ty === "fl")).toBe(false);
  });

  test("removeFill", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("removeFill", 0, 0, "linear")] }], { durationFrames: 15 })))[0]!;
    expect(layer.shapes[0].it.some((s: Dict) => s.ty === "fl")).toBe(false);
  });

  test("removeStroke", () => {
    const layer = nonMatte(compiled(spec([{ target: "test", animations: [prim("removeStroke", 0, 0, "linear")] }], { durationFrames: 15 })))[0]!;
    expect(layer.shapes[0].it.some((s: Dict) => s.ty === "st")).toBe(false);
  });

  test("addStroke", () => {
    const layer = nonMatte(compiled(spec([{
      target: "test",
      animations: [prim("removeFill", 0, 0, "linear"), prim("addStroke", 0, 0, "linear", { color: "#FF0000", strokeWidth: 4 })],
    }], { durationFrames: 15 })))[0]!;
    const items: Dict[] = layer.shapes[0].it;
    const stroke = items.find((s) => s.ty === "st");
    expect(stroke).toBeDefined();
    expect(stroke!.w.k).toBe(4);
    expect(items.some((s) => s.ty === "fl")).toBe(false);
  });

  test("hideLayer", () => {
    const o = layerKS(compiled(spec([{ target: "test", animations: [prim("hideLayer", 0, 0, "linear")] }], { durationFrames: 15 }))).o;
    expect(o.a).toBe(0);
    expect(o.k).toBe(0);
  });

  test("generated layer missing anchor", () => {
    const r = compile(minimalLottie(), spec([{ target: "test", animations: [prim("fadeIn", 0, 0.5)] }], {
      durationFrames: 15,
      generatedLayers: [{ name: "orphan", shape: "ellipse", anchor: "nonexistent" }],
    }));
    expect(r.warnings.some((w) => w.includes("nonexistent"))).toBe(true);
  });

  test("fps clamping", () => {
    expect(compile(minimalLottie(), spec([], { fps: 1000 })).lottie.fr).toBe(60);
  });
});

describe("parseSpec", () => {
  test("parses a full spec", () => {
    const s = parseSpec({
      fps: 60, durationFrames: 120,
      generatedLayers: [{ name: "g", shape: "ellipse", anchor: "a", fillColor: "#fff" }],
      layers: [{ target: "a", staggerDelay: 0.1, animations: [{ kind: "followPath", start: 0, end: 1, easing: "linear", params: { path: [[0, 0], [1, 2]], repeatCount: 2 } }] }],
    });
    expect(s.layers[0]!.animations[0]!.params!.path).toEqual([[0, 0], [1, 2]]);
    expect(s.generatedLayers![0]!.shape).toBe("ellipse");
  });

  test("errors carry a coding path", () => {
    expect(() => parseSpec({ fps: 30, durationFrames: 30, layers: [{ animations: [] }] })).toThrow("missing key 'target' at .layers[0]");
    expect(() => parseSpec({ fps: 30, durationFrames: 30, layers: [{ target: "a", animations: [{ kind: "nope", start: 0, end: 1, easing: "linear" }] }] }))
      .toThrow("Cannot initialize MotionKind from invalid String value nope at .layers[0].animations[0].kind");
  });

  test("null optionals are dropped", () => {
    const s = parseSpec({ fps: 30, durationFrames: 30, generatedLayers: null, layers: [{ target: "a", staggerDelay: null, animations: [{ kind: "fadeIn", start: 0, end: 1, easing: "linear", params: { amount: null } }] }] });
    expect("generatedLayers" in s).toBe(false);
    expect("staggerDelay" in s.layers[0]!).toBe(false);
    expect(s.layers[0]!.animations[0]!.params).toEqual({});
  });
});
