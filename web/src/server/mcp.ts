// MCP-инструменты — порт Sources/MCP/MCPServer.swift + MCPTools.swift (те же имена и аргументы).
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { basename, extname, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import type { Lottie } from "../core/types.ts";
import { Store, type Project, type Version, type Feedback, uuid, now } from "./store.ts";
import { compile, inspectAnimations } from "../core/compiler.ts";
import { parseSpec } from "../core/spec.ts";
import { inputSchema } from "../core/schema.ts";
import { svgToLottie, svgTitle } from "../core/svg.ts";
import * as ov from "../core/overrides.ts";
import * as merge from "../core/merge.ts";
import * as images from "../core/images.ts";
import { readBundle, loadBundle } from "../core/bundle.ts";
import { renderFrames } from "./render.ts";

export class ToolError extends Error {}
export interface ToolOutput { json: any; images?: Uint8Array[] }

const VERSION = "1.0.0";

export class Tools {
  constructor(readonly store: Store, readonly viewer: { url: () => string; open: (path?: string) => void }) {}

  // MARK: lookup

  project(a: any): Project {
    const ref = this.str(a, "project_id");
    const byId = this.store.project(ref.toUpperCase());
    if (byId) return byId;
    const p = this.store.projects().find((x) => x.name.toLowerCase() === ref.toLowerCase());
    if (!p) throw new ToolError(`Project not found: ${ref}. Use list_projects.`);
    return p;
  }

  findVersion(p: Project, ref: string): Version {
    const r = ref.trim().toLowerCase();
    if (r === "latest" && p.versions.length) return p.versions.reduce((a, b) => (b.index > a.index ? b : a));
    const byId = p.versions.find((v) => v.id.toLowerCase() === r);
    if (byId) return byId;
    const n = parseInt(r.startsWith("v") ? r.slice(1) : r, 10);
    const v = p.versions.find((x) => x.index === n);
    if (!v) throw new ToolError(`Version not found: ${ref}. Use list_versions.`);
    return v;
  }

  version(a: any): [Project, Version] { const p = this.project(a); return [p, this.findVersion(p, this.str(a, "version"))]; }
  str(a: any, k: string): string { const v = a?.[k]; if (typeof v !== "string" || !v) throw new ToolError(`Missing '${k}'`); return v; }
  path(p: string): string { return resolve(p.replace(/^~(?=$|[\\/])/, homedir())); }
  geometry(p: Project): Lottie { const g = this.store.geometry(p); if (!g) throw new ToolError("Geometry unavailable"); return g; }
  rect(a: any): images.Rect | null {
    return [a.x, a.y, a.width, a.height].every((v) => typeof v === "number") ? { x: a.x, y: a.y, width: a.width, height: a.height } : null;
  }
  origin(a: any) { return typeof a.x === "number" && typeof a.y === "number" ? { x: a.x, y: a.y } : null; }
  show(projectID: string, extra: { versionID?: string; frame?: number; layer?: string; tap?: number[] } = {}) {
    this.store.writeUICommand({ projectID, ...extra });
  }

  // MARK: serialization

  summary(l: Lottie, bytes?: number) {
    return { w: l.w ?? null, h: l.h ?? null, fr: l.fr ?? null, ip: l.ip ?? null, op: l.op ?? null,
      layers: (l.layers ?? []).map((x: any) => ({ nm: x.nm ?? null, ty: x.ty ?? null })), bytes: bytes ?? JSON.stringify(l).length };
  }
  versionSummary(v: Version) {
    return { id: v.id, label: `v${v.index}`, index: v.index, prompt: v.prompt, note: v.note, source: v.source,
      parentVersionID: v.parentVersionID ?? null, createdAt: v.createdAt, layerCount: v.layerCount,
      compilerWarnings: v.compilerWarnings, favourite: v.isFavourite, hasSpec: v.specJSON != null };
  }
  projectSummary(p: Project) {
    const latest = p.versions.length ? `v${Math.max(...p.versions.map((v) => v.index))}` : null;
    return { id: p.id, name: p.name, source: p.sourceLabel, layerCount: p.layerNames.length, versionCount: p.versions.length,
      latestVersion: latest, updatedAt: p.updatedAt };
  }
  projectDetails(p: Project) {
    const g = this.store.geometry(p);
    return { ...this.projectSummary(p), layers: p.layerNames, createdAt: p.createdAt,
      versions: [...p.versions].sort((a, b) => a.index - b.index).map((v) => this.versionSummary(v)),
      geometrySummary: g ? this.summary(g) : null, viewer: this.viewer.url() };
  }
  feedbackDict(f: Feedback, p: Project) {
    return { id: f.id, project_id: p.id, project: p.name, version: f.versionLabel, versionID: f.versionID ?? null,
      frame: f.frame, layer: f.layer ?? null, text: f.text, resolved: f.resolved, reply: f.reply ?? null, createdAt: f.createdAt };
  }

  // MARK: geometry input

  async geometryInput(a: any): Promise<{ lottie: Lottie; label: string; warnings: string[]; svgText?: string } | null> {
    const asLottie = (x: any) => { const l = typeof x === "string" ? JSON.parse(x) : x; if (!Array.isArray(l?.layers)) throw new ToolError("Not a Lottie JSON (expected an object with 'layers')"); return l; };
    if (typeof a.svg === "string" && a.svg) { const r = await svgToLottie(a.svg); return { lottie: r.lottie, label: "SVG (MCP)", warnings: r.warnings, svgText: a.svg }; }
    if (typeof a.svg_path === "string" && a.svg_path) {
      const p = this.path(a.svg_path); const text = readFileSync(p, "utf8"); const r = await svgToLottie(text);
      return { lottie: r.lottie, label: basename(p), warnings: r.warnings, svgText: text };
    }
    if (a.lottie != null) return { lottie: asLottie(a.lottie), label: "Lottie (MCP)", warnings: [] };
    if (typeof a.lottie_path === "string" && a.lottie_path) { const p = this.path(a.lottie_path); return { lottie: asLottie(readFileSync(p, "utf8")), label: basename(p), warnings: [] }; }
    return null;
  }

  // MARK: assets → scene

  /** Файл из папки ассетов → в сцену. */
  async placeAsset(p: Project, name: string, origin: { x: number; y: number } | null, frame: images.Rect | null) {
    const file = join(this.store.assetsDir(p.id), name);
    if (!existsSync(file)) throw new ToolError(`Asset not found: ${name}. Use list_assets.`);
    const ext = extname(name).toLowerCase(), base = basename(name, extname(name));
    let layer: string, warnings: string[] = [];
    if (ext === ".svg" || ext === ".json") {
      let part: Lottie;
      if (ext === ".svg") { const r = await svgToLottie(readFileSync(file, "utf8")); part = r.lottie; warnings = r.warnings; }
      else part = JSON.parse(readFileSync(file, "utf8"));
      const g = this.geometry(p), cs = merge.size(g) ?? { width: 0, height: 0 }, ps = merge.size(part) ?? { width: 0, height: 0 };
      const r = merge.add(part, g, base, origin ?? { x: (cs.width - ps.width) / 2, y: (cs.height - ps.height) / 2 });
      this.store.setGeometry(p.id, r.lottie); layer = r.group;
    } else {
      const r = images.addImage(this.geometry(p), new Uint8Array(readFileSync(file)), base, frame);
      this.store.setGeometry(p.id, r.lottie); layer = r.layerName;
    }
    this.store.recordUsage(p.id, name, layer);
    return { layer, warnings };
  }

  async importAndPlace(p: Project, src: string, origin: { x: number; y: number } | null, frame: images.Rect | null) {
    return this.placeAsset(p, this.store.copyAsset(p.id, src), origin, frame);
  }

  // MARK: dispatch

  async call(name: string, a: any): Promise<ToolOutput> {
    const s = this.store;
    const J = (json: any): ToolOutput => ({ json });
    switch (name) {
      case "get_guide": return J(this.guide());
      case "open_viewer": this.viewer.open(); return J({ url: this.viewer.url(), note: "Opened in the default browser." });
      case "list_projects": return J(s.projects().map((p) => this.projectSummary(p)));
      case "get_project": return J(this.projectDetails(this.project(a)));
      case "create_project": return J(await this.createProject(a));
      case "rename_project": { const p = this.project(a); s.rename(p.id, this.str(a, "name")); return J(this.projectSummary(s.project(p.id)!)); }
      case "delete_project": { const p = this.project(a); s.delete(p.id); return J({ deleted: p.id }); }
      case "replace_geometry": {
        const p = this.project(a); const g = await this.geometryInput(a);
        if (!g) throw new ToolError("Pass svg, svg_path, lottie or lottie_path");
        s.setGeometry(p.id, g.lottie, g.label);
        return J({ project: this.projectDetails(s.project(p.id)!), svgWarnings: g.warnings });
      }
      case "get_geometry": {
        const p = this.project(a); const g = this.geometry(p);
        const out: any = { layers: p.layerNames, imageFrames: images.imageFrames(g), summary: this.summary(g), animations: inspectAnimations(g) };
        if (a.include_lottie) out.lottie = g;
        return J(out);
      }
      case "validate_spec": return J(this.compileSpec(a, false));
      case "create_version": return J(this.compileSpec(a, true));
      case "create_version_from_lottie": {
        const p = this.project(a); const g = await this.geometryInput(a);
        if (!g) throw new ToolError("Pass lottie (object/string) or lottie_path");
        const parent = typeof a.base_version === "string" && a.base_version ? this.findVersion(p, a.base_version) : undefined;
        const v = s.addVersion(p.id, { prompt: a.prompt ?? "", lottie: g.lottie, layerCount: (g.lottie.layers ?? []).length,
          compilerWarnings: 0, parentVersionID: parent?.id, note: a.note ?? "", source: "import" });
        if (a.show_in_app ?? true) this.show(p.id, { versionID: v.id });
        return J({ version: this.versionSummary(v), summary: this.summary(g.lottie) });
      }
      case "list_versions": return J([...this.project(a).versions].sort((x, y) => x.index - y.index).map((v) => this.versionSummary(v)));
      case "get_version": {
        const [p, v] = this.version(a); const l = s.versionLottie(p.id, v);
        const out: any = { ...this.versionSummary(v), summary: this.summary(l), animations: inspectAnimations(l) };
        if (a.include_spec ?? true) out.spec = v.specJSON ? JSON.parse(v.specJSON) : null;
        if (a.include_lottie) out.lottie = l;
        return J(out);
      }
      case "diff_versions": {
        const p = this.project(a);
        const va = this.findVersion(p, this.str(a, "from")), vb = this.findVersion(p, this.str(a, "to"));
        const specChanges: string[] = [];
        diff(va.specJSON ? JSON.parse(va.specJSON) : null, vb.specJSON ? JSON.parse(vb.specJSON) : null, "spec", specChanges);
        const la = s.versionLottie(p.id, va), lb = s.versionLottie(p.id, vb);
        const lottieChanges: string[] = [];
        if (a.include_lottie_diff) diff(la, lb, "lottie", lottieChanges);
        return J({ from: this.versionSummary(va), to: this.versionSummary(vb), specChanges,
          summaryFrom: this.summary(la), summaryTo: this.summary(lb), lottieChanges: lottieChanges.slice(0, 500), lottieChangesTotal: lottieChanges.length });
      }
      case "restore_version": {
        const [p, v] = this.version(a);
        const nv = s.addVersion(p.id, { prompt: v.prompt, lottie: s.versionLottie(p.id, v), layerCount: v.layerCount,
          compilerWarnings: v.compilerWarnings, specJSON: v.specJSON, parentVersionID: v.id, note: a.note ?? `Restored from v${v.index}`, source: "restore" });
        this.show(p.id, { versionID: nv.id });
        return J({ version: this.versionSummary(nv) });
      }
      case "delete_version": { const [p, v] = this.version(a); s.deleteVersion(p.id, v.id); return J({ deleted: `v${v.index}` }); }
      case "set_favourite": {
        const [p, v] = this.version(a); s.updateVersion(p.id, v.id, (x) => { x.isFavourite = a.favourite ?? true; });
        return J(this.versionSummary(this.version(a)[1]));
      }
      case "set_version_note": {
        const [p, v] = this.version(a); s.updateVersion(p.id, v.id, (x) => { x.note = a.note ?? ""; });
        return J(this.versionSummary(this.version(a)[1]));
      }
      case "export": {
        const p = this.project(a); const out = this.path(this.str(a, "path"));
        const l = typeof a.version === "string" && a.version ? s.versionLottie(p.id, this.findVersion(p, a.version)) : this.geometry(p);
        mkdirSync(dirname(out), { recursive: true });
        const text = JSON.stringify(l);
        writeFileSync(out, text);
        return J({ written: out, bytes: text.length });
      }
      case "show_in_app": {
        const p = this.project(a);
        const vid = typeof a.version === "string" && a.version ? this.findVersion(p, a.version).id : undefined;
        this.show(p.id, { versionID: vid, frame: typeof a.frame === "number" ? a.frame : undefined,
          layer: typeof a.layer === "string" ? a.layer : undefined, tap: Array.isArray(a.tap) ? a.tap : undefined });
        if (a.open_browser) this.viewer.open(`/p/${p.id}`);
        return J({ requested: true, viewer: `${this.viewer.url()}/p/${p.id}`, note: "The viewer page follows within ~1s if it is open. Pass open_browser=true to open it." });
      }
      case "render_frame": return this.renderFrame(a);
      case "device_status": {
        try { const r = await fetch(`${this.viewer.url()}/api/device/status`); return J(await r.json()); }
        catch { return J({ devices: [], note: "Viewer is not running — call open_viewer." }); }
      }
      case "ios_check": {
        const p = this.project(a);
        const l = typeof a.version === "string" && a.version ? s.versionLottie(p.id, this.findVersion(p, a.version)) : this.geometry(p);
        return J(await this.deviceCall("/api/device/check", { lottie: l }));
      }
      case "get_app_state": {
        const st = s.appState();
        if (!st) return J({ running: false, note: `No viewer state yet — open ${this.viewer.url()}` });
        return J({ ...st, secondsSinceUpdate: Math.round((Date.now() - Date.parse(st.updatedAt)) / 1000) });
      }
      case "apply_overrides": {
        const p = this.project(a);
        if (!a.overrides || typeof a.overrides !== "object" || !Object.keys(a.overrides).length)
          throw new ToolError(`Missing 'overrides': {"<layer name>": {"color": "#FF0000", "opacity": 50, "hidden": false}}`);
        const parent = typeof a.version === "string" && a.version ? this.findVersion(p, a.version) : undefined;
        const base = parent ? s.versionLottie(p.id, parent) : this.geometry(p);
        const known = new Set(ov.layers(base).map((l) => l.name));
        const unknown = Object.keys(a.overrides).filter((n) => !known.has(n));
        if (unknown.length) throw new ToolError(`Unknown layers: ${unknown.sort().join(", ")}`);
        const data = ov.apply(a.overrides, base);
        const v = s.addVersion(p.id, { prompt: a.prompt ?? `Overrides on ${parent ? `v${parent.index}` : "geometry"}`, lottie: data,
          layerCount: parent?.layerCount ?? known.size, compilerWarnings: 0, parentVersionID: parent?.id,
          note: a.note ?? Object.keys(a.overrides).sort().join(", "), source: "edit" });
        if (a.show_in_app ?? true) this.show(p.id, { versionID: v.id });
        return J({ version: this.versionSummary(v), summary: this.summary(data) });
      }
      case "add_image": {
        const p = this.project(a);
        if (typeof a.path === "string" && a.path) {
          const { layer } = await this.importAndPlace(p, this.path(a.path), null, this.rect(a));
          this.show(p.id, { layer });
          return J({ layer, frame: images.imageFrames(this.geometry(s.project(p.id)!))[layer] ?? null });
        }
        if (typeof a.base64 === "string") {
          const bytes = Uint8Array.from(Buffer.from(a.base64.split(",").pop()!, "base64"));
          const file = s.writeAsset(p.id, `${a.name ?? "image"}.png`, bytes);
          const { layer } = await this.placeAsset(p, file, null, this.rect(a));
          this.show(p.id, { layer });
          return J({ layer });
        }
        throw new ToolError("Pass 'path' (PNG/JPEG file) or 'base64'");
      }
      case "add_svg": {
        const p = this.project(a);
        if (typeof a.path === "string" && a.path) {
          const { layer, warnings } = await this.importAndPlace(p, this.path(a.path), this.origin(a), null);
          this.show(p.id, { layer });
          return J({ group: layer, warnings });
        }
        if (typeof a.svg === "string" && a.svg) {
          const file = s.writeAsset(p.id, `${a.name ?? svgTitle(a.svg) ?? "svg"}.svg`, new TextEncoder().encode(a.svg));
          const { layer, warnings } = await this.placeAsset(p, file, this.origin(a), null);
          this.show(p.id, { layer });
          return J({ group: layer, warnings });
        }
        throw new ToolError("Pass 'path' (.svg or Lottie .json) or 'svg' markup");
      }
      case "place_layer": {
        const p = this.project(a); const layer = this.str(a, "layer");
        const g = this.geometry(p); const r = this.rect(a);
        if (r && images.imageFrames(g)[layer]) s.setGeometry(p.id, images.place(layer, g, r));
        else if (a.x != null || a.scale != null) s.editGeometry(p.id, (l) => merge.move(layer, l, this.origin(a), typeof a.scale === "number" ? a.scale : null));
        if (a.z != null) {
          const pos = a.z === "top" ? 0 : a.z === "bottom" ? Number.MAX_SAFE_INTEGER : Number(a.z) || 0;
          s.editGeometry(p.id, (l) => merge.reorder(layer, l, pos));
        }
        this.show(p.id, { layer });
        const after = this.geometry(s.project(p.id)!);
        return J({ layer, imageFrame: images.imageFrames(after)[layer] ?? null, order: ov.layers(after).map((l) => l.name) });
      }
      case "rename_layer": {
        const p = this.project(a); const from = this.str(a, "layer"), to = this.str(a, "name");
        s.editGeometry(p.id, (l) => merge.rename(from, to, l));
        const u = s.usage(p.id);
        for (const k of Object.keys(u)) u[k] = u[k].map((n) => (n === from ? to : n));
        s.setUsage(p.id, u);
        return J({ renamed: from, to });
      }
      case "get_feedback": {
        const status = a.status ?? "open";
        const projects = a.project_id ? [this.project(a)] : s.projects();
        const items = projects.flatMap((p) => s.feedback(p.id)
          .filter((f) => status === "all" || (status === "open") !== f.resolved).map((f) => this.feedbackDict(f, p)));
        return J({ count: items.length, items: items.sort((x, y) => x.createdAt.localeCompare(y.createdAt)) });
      }
      case "resolve_feedback": {
        const p = this.project(a); const id = this.str(a, "id").toUpperCase();
        const all = s.feedback(p.id); const f = all.find((x) => x.id === id);
        if (!f) throw new ToolError("Feedback not found");
        f.resolved = a.resolved ?? true; if (typeof a.reply === "string") f.reply = a.reply;
        f.resolvedAt = f.resolved ? now() : undefined;
        s.saveFeedback(p.id, all);
        return J(this.feedbackDict(f, p));
      }
      case "list_assets": {
        const p = this.project(a); const g = this.geometry(p);
        const names = new Set(ov.layers(g).map((l) => l.name)); const u = s.usage(p.id);
        return J({ folder: s.assetsDir(p.id), tip: "Open 'path' with your file reader to look at an asset. place_asset puts one into the scene.",
          assets: s.assets(p.id).map((f) => {
            const d: any = { name: f.name, path: f.path, kind: f.kind, bytes: f.bytes, usedBy: (u[f.name] ?? []).filter((n) => names.has(n)) };
            if (f.kind === "image") { const px = images.pixelSize(new Uint8Array(readFileSync(f.path))); if (px) d.pixels = px; }
            return d;
          }) });
      }
      case "add_assets": {
        const p = this.project(a);
        const paths: string[] = Array.isArray(a.paths) ? a.paths : typeof a.path === "string" ? [a.path] : [];
        if (!paths.length) throw new ToolError("Pass 'paths' (files, folders or .zip)");
        const added: string[] = [];
        for (const raw of paths) {
          const src = this.path(raw);
          if (/\.zip$/i.test(src) || !extname(src)) for (const f of readBundle(src)) added.push(s.writeAsset(p.id, f.name, f.data));
          else added.push(s.copyAsset(p.id, src));
        }
        const placed: string[] = [];
        if (a.place) for (const n of added) placed.push((await this.placeAsset(s.project(p.id)!, n, null, null)).layer);
        return J({ added, placed, folder: s.assetsDir(p.id) });
      }
      case "place_asset": {
        const p = this.project(a);
        const r = await this.placeAsset(p, this.str(a, "name"), this.origin(a), this.rect(a));
        this.show(p.id, { layer: r.layer });
        return J(r);
      }
      case "delete_asset": {
        const p = this.project(a); const n = this.str(a, "name");
        s.trashAsset(p.id, n);
        return J({ trashed: n, note: "Moved to the project's .trash folder (recoverable). Layers already in the scene stay (images are embedded)." });
      }
      default: throw new ToolError(`Unknown tool: ${name}`);
    }
  }

  async createProject(a: any) {
    const s = this.store;
    const name = typeof a.name === "string" && a.name ? a.name : `Untitled ${s.projects().length + 1}`;
    if (typeof a.bundle === "string" && a.bundle) {
      const src = this.path(a.bundle);
      const r = await loadBundle(readBundle(src));
      const p = s.create(s.uniqueName(a.name || basename(src, extname(src))), r.lottie, basename(src));
      for (const f of r.files) s.writeAsset(p.id, f.name, f.data);
      s.setUsage(p.id, r.usage);
      if (a.show_in_app ?? true) this.show(p.id);
      return { project: this.projectDetails(s.project(p.id)!), canvas: r.canvas, parts: r.parts, warnings: r.warnings,
        next: "render_frame to check the layout, place_layer to fix it, rename_layer for meaningful names" };
    }
    const imgs: string[] = Array.isArray(a.images) ? a.images : [];
    if (a.width != null || imgs.length) {
      let w = a.width, h = a.height;
      if (w == null || h == null) {
        const sizes = imgs.map((x) => images.pixelSize(new Uint8Array(readFileSync(this.path(x))))).filter(Boolean) as images.Px[];
        const big = sizes.reduce<images.Px | null>((m, x) => (!m || x.width * x.height > m.width * m.height ? x : m), null);
        w ??= big?.width; h ??= big?.height;
      }
      if (!w || !h) throw new ToolError("Pass width and height (or images)");
      let p = s.create(s.uniqueName(name), images.blank(w, h, a.fps ?? 60, a.frames ?? 120), `Images ${w}×${h}`);
      const added: string[] = [];
      for (const x of [...imgs].reverse()) { added.unshift((await this.importAndPlace(p, this.path(x), null, null)).layer); p = s.project(p.id)!; }
      if (a.show_in_app ?? true) this.show(p.id);
      return { project: this.projectDetails(s.project(p.id)!), imageLayers: added };
    }
    const g = await this.geometryInput(a);
    if (g) {
      const nm = a.name || (g.svgText ? s.uniqueName(svgTitle(g.svgText) ?? basename(g.label, extname(g.label))) : name);
      const p = s.create(nm, g.lottie, g.label);
      if (a.svg_path) s.recordUsage(p.id, s.copyAsset(p.id, this.path(a.svg_path)), "scene");
      if (a.show_in_app ?? true) this.show(p.id);
      return { project: this.projectDetails(p), svgWarnings: g.warnings };
    }
    const p = s.create(name, null, "Sample (rocket)");
    return { project: this.projectDetails(p) };
  }

  compileSpec(a: any, save: boolean) {
    const s = this.store; const p = this.project(a);
    if (a.spec == null) throw new ToolError("Missing 'spec' (AnimationSpec object, see get_guide)");
    let spec;
    try { spec = parseSpec(typeof a.spec === "string" ? JSON.parse(a.spec) : a.spec); }
    catch (e: any) { throw new ToolError(`Invalid AnimationSpec: ${e.message}`); }
    const parent = typeof a.base_version === "string" && a.base_version ? this.findVersion(p, a.base_version) : undefined;
    const base = parent ? s.versionLottie(p.id, parent) : this.geometry(p);
    const result = compile(base, spec);
    const out: any = { warnings: result.warnings, summary: this.summary(result.lottie) };
    if (!save) { if (a.include_lottie) out.lottie = result.lottie; return out; }
    const v = s.addVersion(p.id, { prompt: a.prompt ?? "", lottie: result.lottie, layerCount: spec.layers.length,
      compilerWarnings: result.warnings.length, specJSON: JSON.stringify(spec, null, 2), parentVersionID: parent?.id,
      note: a.note ?? "", source: "mcp" });
    out.version = this.versionSummary(v);
    if (a.show_in_app ?? true) this.show(p.id, { versionID: v.id });
    return out;
  }

  async renderFrame(a: any): Promise<ToolOutput> {
    const p = this.project(a);
    let l: Lottie, label = "geometry";
    if (typeof a.version === "string" && a.version) { const v = this.findVersion(p, a.version); l = this.store.versionLottie(p.id, v); label = `v${v.index}`; }
    else l = this.geometry(p);
    const ip = l.ip ?? 0, op = l.op ?? 1;
    let frames: number[];
    if (Array.isArray(a.frames) && a.frames.length) frames = a.frames.slice(0, 16).map(Number);
    else if (typeof a.count === "number" && a.count > 1) { const c = Math.min(a.count, 16); frames = Array.from({ length: c }, (_, i) => ip + ((op - ip) * i) / (c - 1)); }
    else if (typeof a.frame === "number") frames = [a.frame];
    else frames = [ip + (op - ip) * Math.min(Math.max(a.progress ?? 0, 0), 1)];
    const engine = String(a.engine ?? "skottie");
    if (engine.startsWith("ios")) return this.renderOnDevice(l, label, frames, a, engine);
    const rendered = await renderFrames(l, frames, a.size ?? 512, a.background ?? null);
    const info = rendered.map((r, i) => {
      const d: any = { frame: r.frame, width: r.width, height: r.height };
      if (typeof a.save_dir === "string") {
        const dir = this.path(a.save_dir); mkdirSync(dir, { recursive: true });
        const f = join(dir, `${label}_f${Math.round(r.frame)}_${i}.png`); writeFileSync(f, r.png); d.saved = f;
      }
      return d;
    });
    return { json: { project: p.name, source: label, frames: info, summary: this.summary(l), renderer: "skottie" }, images: rendered.map((r) => r.png) };
  }

  /** Кадры с iPhone (настоящий lottie-ios) через хаб устройств просмотрщика. */
  async deviceCall(path: string, body: any): Promise<any> {
    let r: Response;
    try { r = await fetch(`${this.viewer.url()}${path}`, { method: "POST", body: JSON.stringify(body) }); }
    catch { throw new ToolError("Viewer is not running, so no iPhone can be connected. Call open_viewer first."); }
    const j = await r.json();
    if (!r.ok || j.error) throw new ToolError(j.error ?? `Device request failed (${r.status})`);
    return j;
  }

  async renderOnDevice(l: Lottie, label: string, frames: number[], a: any, engine: string): Promise<ToolOutput> {
    const res = await this.deviceCall("/api/device/render", { lottie: l, frames, size: Math.min(a.size ?? 512, 1024),
      engine: engine === "ios-main-thread" ? "mainThread" : engine === "ios-auto" ? "automatic" : "coreAnimation", background: a.background ?? null });
    const pngs: Uint8Array[] = res.frames.map((f: any) => Uint8Array.from(Buffer.from(f.png, "base64")));
    const info = res.frames.map((f: any, i: number) => {
      const d: any = { frame: f.frame, width: f.width, height: f.height };
      if (typeof a.save_dir === "string") {
        const dir = this.path(a.save_dir); mkdirSync(dir, { recursive: true });
        const file = join(dir, `${label}_ios_f${Math.round(f.frame)}_${i}.png`); writeFileSync(file, pngs[i]); d.saved = file;
      }
      return d;
    });
    return { json: { source: label, frames: info, renderer: `lottie-ios ${res.lottieVersion ?? ""}`.trim(), device: res.device,
      engineRequested: res.engineRequested, engineUsed: res.engineUsed, warnings: res.warnings }, images: pngs };
  }

  guide() {
    const kinds = inputSchema?.properties?.layers?.items?.properties?.animations?.items?.properties?.kind?.enum
      ?? findEnum(inputSchema, "kind") ?? [];
    const easings = findEnum(inputSchema, "easing") ?? [];
    return {
      overview: "You don't write raw Lottie by default. You write an AnimationSpec (JSON, schema below) that says HOW to animate existing layers; a deterministic compiler turns it into Lottie. Layers are referenced by EXACT name (see get_project.layers). For full manual control you can also save raw Lottie with create_version_from_lottie.",
      rules: [
        "fps MUST be 60; durationFrames 1..600 (= seconds × 60); start/end are in SECONDS.",
        `kind ∈ ${kinds.join(", ")}`,
        `easing ∈ ${easings.join(", ")}`,
        "Loops: spin (360°), float (vertical hover), breathe (subtle scale), swing (pendulum).",
        "followPath: params.path = [[dx,dy], ...] offsets from base position, min 2 points.",
        "recolor: params.color hex (\"#FF0000\"); applied at start, end ignored.",
        "Shape edits (removeFill, removeStroke, addStroke{color,strokeWidth}, addFill{color}, hideLayer, showLayer) are INSTANT: use start=0, end=0, easing=linear.",
        "generatedLayers: new ellipse/rectangle layers anchored to existing ones (rings, waves, halos, particles).",
        "Modify mode: pass base_version — only channels you animate are overwritten, the rest stays.",
      ],
      motionTips: [
        "Stagger entrances by 0.05–0.15s; don't start everything at t=0.",
        "Entrances: easeOut or easeOutBack. Settles: spring / easeOutBack. Anticipation: anticipate / easeInBack.",
        "Add idle loops only when asked. One or two subtle accents beat many.",
      ],
      rasterAssets: "Raster flow: create_project(images:[...]) or add_image → get_geometry (imageFrames = layout) → place_layer to arrange → render_frame to check the layout → create_version with an AnimationSpec targeting image layers by name. Image layers support transform motions only.",
      versionRefs: "Versions are referenced by UUID, label \"v3\", number \"3\" or \"latest\". Projects by UUID or exact name.",
      viewer: `The designer watches ${this.viewer.url()} (open_viewer opens it).`,
      schema: inputSchema,
    };
  }
}

function findEnum(o: any, key: string): string[] | null {
  if (!o || typeof o !== "object") return null;
  if (o[key]?.enum) return o[key].enum;
  for (const v of Object.values(o)) { const r = findEnum(v, key); if (r) return r; }
  return null;
}

function diff(a: any, b: any, path: string, out: string[]) {
  const obj = (x: any) => x && typeof x === "object" && !Array.isArray(x);
  if (obj(a) && obj(b)) { for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) diff(a[k] ?? null, b[k] ?? null, `${path}.${k}`, out); return; }
  if (Array.isArray(a) && Array.isArray(b)) { for (let i = 0; i < Math.max(a.length, b.length); i++) diff(a[i] ?? null, b[i] ?? null, `${path}[${i}]`, out); return; }
  const sh = (x: any) => { if (x == null) return "∅"; const s = JSON.stringify(x); return s.length > 120 ? s.slice(0, 117) + "…" : s; };
  if (sh(a) !== sh(b)) out.push(`${path}: ${sh(a)} → ${sh(b)}`);
}
