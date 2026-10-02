// Порт Sources/AI/Spec/AnimationSpec.swift.
//
// Компактный промежуточный DSL, который выдаёт LLM (structured output). LLM никогда не пишет
// Lottie JSON напрямую: он описывает анимацию поверх именованных слоёв статичного Lottie, а
// детерминированный компилятор (compiler.ts) превращает spec в валидные keyframes.

export const minFPS = 24;
export const maxFPS = 60;
export const maxDurationFrames = 600;

export const motionKinds = [
  "fadeIn", "fadeOut", "slideIn", "slideOut", "scaleIn", "scaleOut", "rotate", "pulse", "bounce",
  "drawOn", "wiggle",
  // M4 — idle/accent loops
  "spin", "float", "breathe", "swing", "followPath", "recolor",
  // M5 — расширенные примитивы
  "squash", "stretch", "flash", "flip", "colorTransition", "blurIn", "blurOut",
  // M6 — shape-edit примитивы (мгновенные, start/end игнорируются)
  "removeFill", "removeStroke", "addStroke", "addFill", "hideLayer", "showLayer",
] as const;
export type MotionKind = (typeof motionKinds)[number];

export const easings = [
  "linear", "easeIn", "easeOut", "easeInOut", "spring",
  "easeOutBack", "easeInBack", "easeInOutBack", "anticipate",
  "elastic",
] as const;
export type Easing = (typeof easings)[number];

export const generatedShapes = ["ellipse", "rectangle"] as const;
export type GeneratedShape = (typeof generatedShapes)[number];

/** Объединённый набор параметров для всех примитивов. Каждый kind читает только релевантные поля. */
export interface MotionParams {
  direction?: string;
  distance?: number;
  from?: number;
  to?: number;
  fromDeg?: number;
  toDeg?: number;
  amount?: number;
  frequency?: number;
  /** Целое (Swift Int). */
  repeatCount?: number;
  path?: number[][];
  color?: string;
  fromColor?: string;
  blurAmount?: number;
  axis?: string;
  strokeWidth?: number;
}

export interface MotionPrimitive {
  kind: MotionKind;
  /** Старт в секундах от начала композиции. */
  start: number;
  /** Конец в секундах. */
  end: number;
  easing: Easing;
  params?: MotionParams;
}

export interface LayerAnimationSpec {
  /** Имя слоя (nm). Поддерживает wildcard `*` в конце (или в начале). */
  target: string;
  animations: MotionPrimitive[];
  /** Задержка (сек) между совпавшими слоями при wildcard-матчинге. */
  staggerDelay?: number;
}

export interface GeneratedLayer {
  name: string;
  shape: GeneratedShape;
  anchor: string;
  width?: number;
  height?: number;
  fillColor?: string;
  strokeColor?: string;
  strokeWidth?: number;
  opacity?: number;
}

export interface AnimationSpec {
  /** Целое. Компилятор клампит в 24…60. */
  fps: number;
  /** Целое. Компилятор клампит в 1…600. */
  durationFrames: number;
  layers: LayerAnimationSpec[];
  generatedLayers?: GeneratedLayer[];
}

// MARK: - Decoding (как Swift JSONDecoder + Decodable)

type Path = (string | number)[];

class SpecDecodingError extends Error {}

function pathString(path: Path): string {
  return path.map((p) => (typeof p === "number" ? `[${p}]` : `.${p}`)).join("");
}

function fail(debug: string, path: Path): never {
  throw new SpecDecodingError(`${debug} at ${pathString(path)}`);
}

/** Как Swift описывает найденный JSON-тип в typeMismatch. */
function foundDescription(v: unknown): string {
  if (typeof v === "string") return "a string";
  if (typeof v === "boolean") return "bool";
  if (typeof v === "number") return "number";
  if (Array.isArray(v)) return "an array";
  return "a dictionary";
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function keyed(v: unknown, path: Path): Record<string, unknown> {
  if (v === null || v === undefined) fail("Cannot get keyed decoding container -- found null value instead", path);
  if (!isObject(v)) fail(`Expected to decode Dictionary<String, Any> but found ${foundDescription(v)} instead.`, path);
  return v;
}

function unkeyed(v: unknown, path: Path): unknown[] {
  if (v === null || v === undefined) fail("Cannot get unkeyed decoding container -- found null value instead", path);
  if (!Array.isArray(v)) fail(`Expected to decode Array<Any> but found ${foundDescription(v)} instead.`, path);
  return v;
}

function decodeDouble(v: unknown, path: Path): number {
  if (v === null || v === undefined) fail("Cannot get value of type Double -- found null value instead", path);
  if (typeof v !== "number") fail(`Expected to decode Double but found ${foundDescription(v)} instead.`, path);
  return v;
}

const int64Limit = 2 ** 63;

function decodeInt(v: unknown, path: Path): number {
  if (v === null || v === undefined) fail("Cannot get value of type Int -- found null value instead", path);
  if (typeof v !== "number") fail(`Expected to decode Int but found ${foundDescription(v)} instead.`, path);
  // Swift сообщает о дробном / не влезающем в Int64 числе как о повреждённых данных у корня.
  if (!Number.isInteger(v) || v >= int64Limit || v < -int64Limit) fail("The given data was not valid JSON.", []);
  return v;
}

function decodeString(v: unknown, path: Path): string {
  if (v === null || v === undefined) fail("Cannot get value of type String -- found null value instead", path);
  if (typeof v !== "string") fail(`Expected to decode String but found ${foundDescription(v)} instead.`, path);
  return v;
}

function decodeEnum<T extends string>(v: unknown, path: Path, typeName: string, cases: readonly T[]): T {
  const s = decodeString(v, path);
  if (!(cases as readonly string[]).includes(s)) fail(`Cannot initialize ${typeName} from invalid String value ${s}`, path);
  return s as T;
}

function present(obj: Record<string, unknown>, key: string): boolean {
  return key in obj && obj[key] !== null && obj[key] !== undefined;
}

function missing(key: string, path: Path): never {
  throw new SpecDecodingError(`missing key '${key}' at ${pathString(path)}`);
}

function required(obj: Record<string, unknown>, key: string, path: Path): unknown {
  if (!(key in obj) || obj[key] === undefined) missing(key, path);
  return obj[key];
}

function optDouble(obj: Record<string, unknown>, key: string, path: Path): number | undefined {
  return present(obj, key) ? decodeDouble(obj[key], [...path, key]) : undefined;
}

function optInt(obj: Record<string, unknown>, key: string, path: Path): number | undefined {
  return present(obj, key) ? decodeInt(obj[key], [...path, key]) : undefined;
}

function optString(obj: Record<string, unknown>, key: string, path: Path): string | undefined {
  return present(obj, key) ? decodeString(obj[key], [...path, key]) : undefined;
}

function assignDefined<T extends object>(target: T, values: Record<string, unknown>): T {
  for (const [k, v] of Object.entries(values)) if (v !== undefined) (target as any)[k] = v;
  return target;
}

function decodeParams(v: unknown, path: Path): MotionParams {
  const o = keyed(v, path);
  let pathValue: number[][] | undefined;
  if (present(o, "path")) {
    const pp = [...path, "path"];
    pathValue = unkeyed(o.path, pp).map((pt, i) =>
      unkeyed(pt, [...pp, i]).map((n, j) => decodeDouble(n, [...pp, i, j])),
    );
  }
  return assignDefined({} as MotionParams, {
    direction: optString(o, "direction", path),
    distance: optDouble(o, "distance", path),
    from: optDouble(o, "from", path),
    to: optDouble(o, "to", path),
    fromDeg: optDouble(o, "fromDeg", path),
    toDeg: optDouble(o, "toDeg", path),
    amount: optDouble(o, "amount", path),
    frequency: optDouble(o, "frequency", path),
    repeatCount: optInt(o, "repeatCount", path),
    path: pathValue,
    color: optString(o, "color", path),
    fromColor: optString(o, "fromColor", path),
    blurAmount: optDouble(o, "blurAmount", path),
    axis: optString(o, "axis", path),
    strokeWidth: optDouble(o, "strokeWidth", path),
  });
}

function decodePrimitive(v: unknown, path: Path): MotionPrimitive {
  const o = keyed(v, path);
  // Порядок проверки ключей — как в синтезированном init(from:) (порядок объявления свойств).
  const kind = decodeEnum(required(o, "kind", path), [...path, "kind"], "MotionKind", motionKinds);
  const start = decodeDouble(required(o, "start", path), [...path, "start"]);
  const end = decodeDouble(required(o, "end", path), [...path, "end"]);
  const easing = decodeEnum(required(o, "easing", path), [...path, "easing"], "Easing", easings);
  const params = present(o, "params") ? decodeParams(o.params, [...path, "params"]) : undefined;
  return assignDefined({ kind, start, end, easing } as MotionPrimitive, { params });
}

function decodeLayer(v: unknown, path: Path): LayerAnimationSpec {
  const o = keyed(v, path);
  const target = decodeString(required(o, "target", path), [...path, "target"]);
  const ap = [...path, "animations"];
  const animations = unkeyed(required(o, "animations", path), ap).map((a, i) => decodePrimitive(a, [...ap, i]));
  const staggerDelay = optDouble(o, "staggerDelay", path);
  return assignDefined({ target, animations } as LayerAnimationSpec, { staggerDelay });
}

function decodeGenerated(v: unknown, path: Path): GeneratedLayer {
  const o = keyed(v, path);
  const name = decodeString(required(o, "name", path), [...path, "name"]);
  const shape = decodeEnum(required(o, "shape", path), [...path, "shape"], "GeneratedShape", generatedShapes);
  const anchor = decodeString(required(o, "anchor", path), [...path, "anchor"]);
  return assignDefined({ name, shape, anchor } as GeneratedLayer, {
    width: optDouble(o, "width", path),
    height: optDouble(o, "height", path),
    fillColor: optString(o, "fillColor", path),
    strokeColor: optString(o, "strokeColor", path),
    strokeWidth: optDouble(o, "strokeWidth", path),
    opacity: optDouble(o, "opacity", path),
  });
}

/**
 * Разбирает и валидирует spec так же, как Swift `JSONDecoder().decode(AnimationSpec.self, …)`:
 * обязательные ключи, типы, значения enum; лишние ключи игнорируются, null у опциональных = отсутствие.
 * Строку принимает как JSON-текст. Ошибка — Error с текстом вида "missing key 'target' at .layers[0]".
 */
export function parseSpec(obj: unknown): AnimationSpec {
  let value = obj;
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      throw new SpecDecodingError("The given data was not valid JSON. at ");
    }
  }
  const o = keyed(value, []);
  const fps = decodeInt(required(o, "fps", []), ["fps"]);
  const durationFrames = decodeInt(required(o, "durationFrames", []), ["durationFrames"]);
  const layers = unkeyed(required(o, "layers", []), ["layers"]).map((l, i) => decodeLayer(l, ["layers", i]));
  let generatedLayers: GeneratedLayer[] | undefined;
  if (present(o, "generatedLayers")) {
    generatedLayers = unkeyed(o.generatedLayers, ["generatedLayers"]).map((g, i) =>
      decodeGenerated(g, ["generatedLayers", i]),
    );
  }
  return assignDefined({ fps, durationFrames, layers } as AnimationSpec, { generatedLayers });
}
