// Golden-сравнение TS-компилятора с эталоном Swift (фикстуры из gen-compiler-fixtures.ts).

import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { compile, inspectAnimations } from "../src/core/compiler";
import { inputSchema } from "../src/core/schema";
import { parseSpec } from "../src/core/spec";
import { fixturesDir, inputs } from "./compiler-cases";

const readJSON = (file: string) => JSON.parse(readFileSync(file, "utf8"));

/** Глубокое сравнение; числа — с точностью 1e-6. Возвращает путь первого расхождения или null. */
export function diffClose(a: any, b: any, path = ""): string | null {
  if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) <= 1e-6 ? null : `${path}: ${a} != ${b}`;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return `${path}: ${JSON.stringify(a)?.slice(0, 80)} != ${JSON.stringify(b)?.slice(0, 80)}`;
    if (a.length !== b.length) return `${path}: length ${a.length} != ${b.length}`;
    for (let i = 0; i < a.length; i++) {
      const d = diffClose(a[i], b[i], `${path}[${i}]`);
      if (d) return d;
    }
    return null;
  }
  if (a && b && typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    if (ka.join("\u0000") !== kb.join("\u0000")) return `${path}: keys [${ka}] != [${kb}]`;
    for (const k of ka) {
      const d = diffClose(a[k], b[k], `${path}.${k}`);
      if (d) return d;
    }
    return null;
  }
  return a === b ? null : `${path}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`;
}

const inputCache = new Map<string, any>();
const loadInput = (key: string) => {
  if (!inputCache.has(key)) inputCache.set(key, readJSON(inputs[key]!));
  return inputCache.get(key);
};

const caseFiles = readdirSync(fixturesDir).filter((f) => f.endsWith(".json") && !f.startsWith("_")).sort();

describe("compiler golden (Swift lottie-mcp)", () => {
  test("fixtures exist", () => {
    expect(caseFiles.length).toBeGreaterThan(50);
  });

  for (const file of caseFiles) {
    const fx = readJSON(join(fixturesDir, file));
    test(fx.name, () => {
      const input = loadInput(fx.input);
      const before = JSON.stringify(input);
      const result = compile(input, parseSpec(fx.spec));
      expect(JSON.stringify(input)).toBe(before); // вход не мутируется
      expect(diffClose(result.lottie, fx.lottie)).toBeNull();
      expect(result.warnings).toEqual(fx.warnings);
      expect(inspectAnimations(result.lottie)).toBe(fx.animations);
    });
  }
});

describe("inspectAnimations golden", () => {
  for (const fx of readJSON(join(fixturesDir, "_inspect.json"))) {
    test(fx.name, () => {
      const lottie = fx.name.startsWith("input:") ? loadInput(fx.name.slice(6)) : fx.lottie;
      expect(inspectAnimations(lottie)).toBe(fx.animations);
    });
  }
});

describe("parseSpec golden (Swift JSONDecoder errors)", () => {
  readJSON(join(fixturesDir, "_spec-parse.json")).forEach((fx: { spec: unknown; error: string | null }, i: number) => {
    test(`#${i} ${JSON.stringify(fx.spec).slice(0, 90)}`, () => {
      let message: string | null = null;
      try {
        parseSpec(fx.spec);
      } catch (e) {
        message = (e as Error).message;
      }
      expect(message).toBe(fx.error);
    });
  });
});

test("inputSchema matches Swift get_guide.schema", () => {
  expect(diffClose(inputSchema, readJSON(join(fixturesDir, "_schema.json")))).toBeNull();
});
