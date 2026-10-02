// Хранилище проектов на диске — порт ProjectStore.swift. Формат файлов совпадает с Mac-версией:
// <root>/projects/<UUID>/project.json, static.json, versions/<file>.json, feedback.json, assets/ (+ .usage.json).
import { mkdirSync, existsSync, readdirSync, readFileSync, writeFileSync, rmSync, statSync, copyFileSync, renameSync } from "node:fs";
import { join, basename, extname } from "node:path";
import { homedir, platform } from "node:os";
import type { Lottie } from "../core/types.ts";
import { layers as listLayers } from "../core/overrides.ts";
import sample from "../../../Sources/Resources/rocket_static_simplified.json" with { type: "json" };

export interface Version {
  id: string; index: number; prompt: string; createdAt: string; compiledFile: string;
  layerCount: number; compilerWarnings: number; specJSON?: string; isFavourite: boolean;
  parentVersionID?: string; note: string; source: string;
}
export interface Project {
  id: string; name: string; createdAt: string; updatedAt: string; hasImportedStatic: boolean;
  layerNames: string[]; sourceLabel: string; versions: Version[];
}
export interface Feedback {
  id: string; versionID?: string; versionLabel: string; frame: number; layer?: string; text: string;
  createdAt: string; resolved: boolean; reply?: string; resolvedAt?: string;
}
export interface UICommand { projectID?: string; versionID?: string; issuedAt: string; frame?: number; layer?: string; tap?: number[] }

export const uuid = () => crypto.randomUUID().toUpperCase();
/** ISO-8601 без долей секунды — как JSONEncoder.dateEncodingStrategy = .iso8601 в Swift. */
export const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

function defaultBase(): string {
  if (process.env.LOTTIE_DEV_HOME) return process.env.LOTTIE_DEV_HOME;
  if (platform() === "darwin") return join(homedir(), "Library/Application Support/LottieDeveloperMac");
  if (platform() === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData/Roaming"), "LottieDeveloper");
  return join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local/share"), "LottieDeveloper");
}

const readJSON = <T>(p: string): T | null => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };
/** JSON как у Swift (.prettyPrinted, .sortedKeys): ключи по алфавиту, 2 пробела. */
function sortedJSON(v: any): string {
  const sort = (x: any): any => Array.isArray(x) ? x.map(sort)
    : x && typeof x === "object" ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, sort(x[k])])) : x;
  return JSON.stringify(sort(v), null, 2);
}
function writeAtomic(p: string, data: string | Uint8Array) {
  const tmp = `${p}.${process.pid}.tmp`;
  writeFileSync(tmp, data);
  renameSync(tmp, p);
}

export class Store {
  readonly base = defaultBase();
  readonly root = join(this.base, "projects");

  constructor() { mkdirSync(this.root, { recursive: true }); }

  dir(id: string) { const d = join(this.root, id); mkdirSync(d, { recursive: true }); return d; }
  staticPath(id: string) { return join(this.dir(id), "static.json"); }
  versionsDir(id: string) { const d = join(this.dir(id), "versions"); mkdirSync(d, { recursive: true }); return d; }
  versionPath(id: string, file: string) { return join(this.versionsDir(id), file); }
  assetsDir(id: string) { return join(this.dir(id), "assets"); }

  // MARK: projects

  projects(): Project[] {
    const out: Project[] = [];
    for (const e of readdirSync(this.root, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const p = readJSON<Project>(join(this.root, e.name, "project.json"));
      if (p) out.push(p);
    }
    return out.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  project(id: string): Project | null {
    return existsSync(join(this.root, id, "project.json")) ? readJSON<Project>(join(this.root, id, "project.json")) : null;
  }

  save(p: Project) {
    p.updatedAt = now();
    const clean = { ...p, versions: p.versions.map((v) => Object.fromEntries(Object.entries(v).filter(([, x]) => x !== undefined && x !== null))) };
    writeAtomic(join(this.dir(p.id), "project.json"), sortedJSON(clean));
  }

  uniqueName(base: string): string {
    const names = new Set(this.projects().map((p) => p.name));
    if (!names.has(base)) return base;
    let i = 2; while (names.has(`${base} ${i}`)) i++;
    return `${base} ${i}`;
  }

  create(name: string, geometry: Lottie | null, sourceLabel: string): Project {
    const t = now();
    const p: Project = { id: uuid(), name, createdAt: t, updatedAt: t, hasImportedStatic: geometry != null,
      layerNames: listLayers(geometry ?? (sample as Lottie)).map((l) => l.name), sourceLabel, versions: [] };
    if (geometry) writeAtomic(this.staticPath(p.id), JSON.stringify(geometry));
    this.save(p);
    return p;
  }

  geometry(p: Project): Lottie | null {
    if (!p.hasImportedStatic) return structuredClone(sample as Lottie);
    return readJSON<Lottie>(this.staticPath(p.id));
  }

  setGeometry(id: string, lottie: Lottie, sourceLabel?: string) {
    const p = this.project(id);
    if (!p) throw new Error("Project not found");
    writeAtomic(this.staticPath(id), JSON.stringify(lottie));
    p.hasImportedStatic = true;
    p.layerNames = listLayers(lottie).map((l) => l.name);
    if (sourceLabel) p.sourceLabel = sourceLabel;
    this.save(p);
  }

  editGeometry(id: string, edit: (l: Lottie) => Lottie) {
    const p = this.project(id);
    const g = p && this.geometry(p);
    if (!p || !g) throw new Error("Project not found");
    this.setGeometry(id, edit(g));
  }

  rename(id: string, name: string) { const p = this.project(id); if (p) { p.name = name; this.save(p); } }
  delete(id: string) { rmSync(join(this.root, id), { recursive: true, force: true }); }

  // MARK: versions

  addVersion(id: string, v: { prompt: string; lottie: Lottie; layerCount: number; compilerWarnings: number;
    specJSON?: string; parentVersionID?: string; note?: string; source?: string }): Version {
    const p = this.project(id);
    if (!p) throw new Error("Project not found");
    const index = Math.max(0, ...p.versions.map((x) => x.index)) + 1;
    const file = `v${index}_${uuid()}.json`;
    writeAtomic(this.versionPath(id, file), JSON.stringify(v.lottie));
    const ver: Version = { id: uuid(), index, prompt: v.prompt, createdAt: now(), compiledFile: file,
      layerCount: v.layerCount, compilerWarnings: v.compilerWarnings, specJSON: v.specJSON, isFavourite: false,
      parentVersionID: v.parentVersionID, note: v.note ?? "", source: v.source ?? "mcp" };
    p.versions.push(ver);
    this.save(p);
    return ver;
  }

  versionLottie(id: string, v: Version): Lottie {
    const l = readJSON<Lottie>(this.versionPath(id, v.compiledFile));
    if (!l) throw new Error(`Version file missing: ${v.compiledFile}`);
    return l;
  }

  updateVersion(id: string, vid: string, f: (v: Version) => void) {
    const p = this.project(id); const v = p?.versions.find((x) => x.id === vid);
    if (!p || !v) throw new Error("Version not found");
    f(v); this.save(p);
  }

  deleteVersion(id: string, vid: string) {
    const p = this.project(id); const v = p?.versions.find((x) => x.id === vid);
    if (!p || !v) return;
    rmSync(this.versionPath(id, v.compiledFile), { force: true });
    p.versions = p.versions.filter((x) => x.id !== vid);
    this.save(p);
  }

  // MARK: feedback

  feedback(id: string): Feedback[] { return readJSON<Feedback[]>(join(this.dir(id), "feedback.json")) ?? []; }
  saveFeedback(id: string, items: Feedback[]) {
    const clean = items.map((f) => Object.fromEntries(Object.entries(f).filter(([, x]) => x !== undefined && x !== null)));
    writeAtomic(join(this.dir(id), "feedback.json"), sortedJSON(clean));
  }

  // MARK: assets

  assets(id: string): { name: string; path: string; bytes: number; kind: string; modified: number }[] {
    const d = this.assetsDir(id);
    if (!existsSync(d)) return [];
    return readdirSync(d).filter((n) => !n.startsWith(".") && SUPPORTED.has(extname(n).slice(1).toLowerCase())).map((n) => {
      const st = statSync(join(d, n));
      const ext = extname(n).slice(1).toLowerCase();
      return { name: n, path: join(d, n), bytes: st.size, modified: st.mtimeMs, kind: ext === "svg" ? "svg" : ext === "json" ? "lottie" : "image" };
    }).sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  }

  /** Скопировать файл в папку ассетов без перезаписи ("name 2.png"); тот же файл — не дублировать. */
  copyAsset(id: string, src: string): string {
    const d = this.assetsDir(id);
    mkdirSync(d, { recursive: true });
    const ext = extname(src), base = basename(src, ext);
    let dst = join(d, basename(src));
    const same = (a: string, b: string) => { try { return readFileSync(a).equals(readFileSync(b)); } catch { return false; } };
    if (existsSync(dst) && same(dst, src)) return basename(dst);
    let i = 2;
    while (existsSync(dst)) dst = join(d, `${base} ${i++}${ext}`);
    copyFileSync(src, dst);
    return basename(dst);
  }

  writeAsset(id: string, name: string, data: Uint8Array): string {
    const d = this.assetsDir(id);
    mkdirSync(d, { recursive: true });
    const ext = extname(name), base = basename(name, ext);
    let dst = join(d, basename(name)), i = 2;
    while (existsSync(dst)) dst = join(d, `${base} ${i++}${ext}`);
    writeFileSync(dst, data);
    return basename(dst);
  }

  usage(id: string): Record<string, string[]> { return readJSON(join(this.assetsDir(id), ".usage.json")) ?? {}; }
  setUsage(id: string, u: Record<string, string[]>) {
    mkdirSync(this.assetsDir(id), { recursive: true });
    writeAtomic(join(this.assetsDir(id), ".usage.json"), sortedJSON(Object.fromEntries(Object.entries(u).filter(([, v]) => v.length))));
  }
  recordUsage(id: string, file: string, layer: string) {
    const u = this.usage(id);
    if (!(u[file] ?? []).includes(layer)) (u[file] ??= []).push(layer);
    this.setUsage(id, u);
  }

  /** Удаление ассета: в Mac-версии — в Корзину; здесь — в скрытую папку .trash проекта (восстановимо). */
  trashAsset(id: string, name: string) {
    const src = join(this.assetsDir(id), name);
    if (!existsSync(src)) throw new Error(`Asset not found: ${name}`);
    const trash = join(this.dir(id), ".trash");
    mkdirSync(trash, { recursive: true });
    renameSync(src, join(trash, `${Date.now()}_${name}`));
    const u = this.usage(id); delete u[name]; this.setUsage(id, u);
  }

  // MARK: UI command / state (общие с Mac-приложением и веб-просмотрщиком)

  writeUICommand(c: Omit<UICommand, "issuedAt">) {
    writeAtomic(join(this.base, "ui_command.json"), sortedJSON({ ...c, issuedAt: now() }));
  }
  uiCommand(): UICommand | null { return readJSON(join(this.base, "ui_command.json")); }
  appState(): any { return readJSON(join(this.base, "ui_state.json")); }
  writeAppState(s: any) { writeAtomic(join(this.base, "ui_state.json"), sortedJSON({ ...s, updatedAt: now() })); }
}

export const SUPPORTED = new Set(["svg", "png", "jpg", "jpeg", "webp", "json"]);
