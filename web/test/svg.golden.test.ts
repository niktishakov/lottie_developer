// Golden-тест SVG-импорта: TS-порт против выхода Swift (фикстуры — test/gen-svg-fixtures.ts).
// Векторные слои — deep-equal (числа с точностью 1e-6); слои-картинки — имя/порядок/ty/refId,
// прямоугольник на холсте ±1.5 px, размер ассета ±3 px (PNG разные: resvg vs CoreSVG).
import { describe, expect, test } from "bun:test";
import { readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { decode } from "fast-png";
import { svgToLottie, svgTitle, parsePath } from "../src/core/svg.ts";
import { parseSVG, serialize, isolate, rasterNodes } from "../src/core/svgDom.ts";

const DIR = join(import.meta.dir, "fixtures/svg");
const OUT = join(import.meta.dir, "out");
const svgs = readdirSync(DIR).filter((f) => f.endsWith(".svg")).sort();

function diff(a: any, b: any, path: string, out: string[]) {
  if (out.length > 20) return;
  if (typeof a === "number" && typeof b === "number") {
    if (Math.abs(a - b) > 1e-6) out.push(`${path}: ${a} != ${b}`);
    return;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) { out.push(`${path}: array mismatch`); return; }
    a.forEach((v, i) => diff(v, b[i], `${path}[${i}]`, out));
    return;
  }
  if (a && b && typeof a === "object" && typeof b === "object") {
    const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
    if (ka.join() !== kb.join()) { out.push(`${path}: keys ${ka} != ${kb}`); return; }
    for (const k of ka) diff(a[k], b[k], `${path}.${k}`, out);
    return;
  }
  if (a !== b) out.push(`${path}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
}

/**
 * Известные расхождения рендереров (resvg vs CoreSVG/NSImage):
 * - contains: CoreSVG молча игнорирует Figma-фильтры (feFlood/feBlend/feGaussianBlur, filterUnits=userSpaceOnUse) —
 *   Swift-картинка без размытия/тени. resvg рисует эффект, поэтому его прямоугольник шире и должен содержать Swift-овский.
 * - blur: обычный feGaussianBlur оба рисуют, но хвост размытия (alpha > 2) у CoreSVG чуть длиннее (resvg режет гауссов хвост box-blur-ом) — допуск ±4 px / ±12 px.
 */
const KNOWN: Record<string, { kind: "contains" | "blur" }> = {
  "Line.svg/group-1": { kind: "contains" },
  "Content.svg/group-14": { kind: "contains" },
  "raster.svg/blurred": { kind: "blur" },
  "raster.svg/outer-rect-5": { kind: "blur" },
};

function imageRect(layer: any, asset: any) {
  const w = (asset.w * layer.ks.s.k[0]) / 100, h = (asset.h * layer.ks.s.k[1]) / 100;
  return { x: layer.ks.p.k[0] - w / 2, y: layer.ks.p.k[1] - h / 2, w, h };
}

describe("svgToLottie vs Swift golden", () => {
  for (const f of svgs) {
    test(f, async () => {
      const golden = await Bun.file(join(DIR, f.replace(/\.svg$/, ".lottie.json"))).json();
      const res = await svgToLottie(await Bun.file(join(DIR, f)).text());
      const G = golden.lottie, T = res.lottie;

      expect(res.layerNames).toEqual(golden.layerNames);
      expect(res.warnings).toEqual(golden.warnings);

      const errs: string[] = [];
      const { layers: gl, assets: ga, ...gTop } = G;
      const { layers: tl, assets: ta, ...tTop } = T;
      diff(tTop, gTop, "root", errs);
      expect(tl.length).toBe(gl.length);
      expect(ta.length).toBe(ga.length);

      tl.forEach((t: any, i: number) => {
        const g = gl[i];
        if (g.ty !== 2) { diff(t, g, `layers[${i}](${g.nm})`, errs); return; }
        expect(t.ty).toBe(2);
        expect(t.nm).toBe(g.nm);
        expect(t.ind).toBe(g.ind);
        expect(t.refId).toMatch(/^svg_raster_\d+$/);
        expect(t.refId).toBe(g.refId);
        const { ks: tks, ...tRest } = t, { ks: gks, ...gRest } = g;
        diff(tRest, gRest, `layers[${i}]`, errs);
        const tAsset = ta.find((a: any) => a.id === t.refId), gAsset = ga.find((a: any) => a.id === g.refId);
        expect(tAsset.p.startsWith("data:image/png;base64,")).toBe(true);
        expect(tAsset.e).toBe(1);
        const tr = imageRect(t, tAsset), gr = imageRect(g, gAsset);
        const known = KNOWN[`${f}/${g.nm}`];
        if (known?.kind === "contains") {
          // CoreSVG не применил фильтр — у Swift только сама фигура; у resvg она + размытие/тень вокруг.
          const eps = 1.5;
          const ok = tr.x <= gr.x + eps && tr.y <= gr.y + eps && tr.x + tr.w >= gr.x + gr.w - eps && tr.y + tr.h >= gr.y + gr.h - eps;
          if (!ok) errs.push(`layers[${i}](${g.nm}) TS rect ${JSON.stringify(tr)} must contain Swift ${JSON.stringify(gr)}`);
        } else {
          const rectTol = known?.kind === "blur" ? 4 : 1.5, pxTol = known?.kind === "blur" ? 12 : 3;
          expect(Math.abs(tAsset.w - gAsset.w)).toBeLessThanOrEqual(pxTol);
          expect(Math.abs(tAsset.h - gAsset.h)).toBeLessThanOrEqual(pxTol);
          for (const k of ["x", "y", "w", "h"] as const) {
            if (Math.abs(tr[k] - gr[k]) > rectTol) errs.push(`layers[${i}](${g.nm}) rect.${k}: ${tr[k]} vs ${gr[k]}`);
          }
        }
        // anchor — центр картинки, scale — rect / px
        expect(tks.a.k).toEqual([tAsset.w / 2, tAsset.h / 2, 0]);
        expect(tks.s.k[0]).toBeCloseTo(100 / 3, 6);
        expect(tks.s.k[1]).toBeCloseTo(100 / 3, 6);
      });
      expect(errs).toEqual([]);

      // визуальная проверка: растровые слои в test/out/
      if (ta.length > 0) {
        mkdirSync(OUT, { recursive: true });
        for (const a of ta) {
          const png = Buffer.from(a.p.split(",")[1], "base64");
          const img = decode(png);
          expect(img.width).toBe(a.w);
          expect(img.height).toBe(a.h);
          writeFileSync(join(OUT, `${f.replace(/\.svg$/, "")}-${a.id}.png`), png);
        }
      }
    });
  }
});

describe("svgTitle", () => {
  test("title tag, trimmed, entities as-is from source", () => {
    expect(svgTitle("<svg><title>  Hello  </title></svg>")).toBe("Hello");
    expect(svgTitle("<svg id=\"Root\"><title>   </title></svg>")).toBe("Root");
    expect(svgTitle("<svg xmlns=\"x\" id=\"Root\"></svg>")).toBe("Root");
    expect(svgTitle("<svg></svg>")).toBeNull();
    expect(svgTitle(`<svg><title>${"a".repeat(80)}</title></svg>`)).toBe("a".repeat(60));
    expect(svgTitle("<svg><TITLE lang=\"en\">\nMulti\nline\n</TITLE></svg>")).toBe("Multi\nline");
  });
});

describe("svgDom", () => {
  test("parses declaration, doctype entities, comments, CDATA, self-closing, entities", () => {
    const root = parseSVG(`<?xml version="1.0"?>
<!DOCTYPE svg [ <!ENTITY c "#abc"> ]>
<svg a="1&amp;2" b='x&#10;y' c="&c;"><!-- <g/> --><style><![CDATA[ .a{} ]]></style><title> A &lt; B </title><rect/></svg>`)!;
    expect(root.tag).toBe("svg");
    expect(root.attrs).toEqual({ a: "1&2", b: "x\ny", c: "#abc" });
    expect(root.children.map((c) => c.tag)).toEqual(["style", "title", "rect"]);
    expect(root.children[0].text).toBe("");
    expect(root.children[1].text).toBe("A<B");
    expect(serialize(root.children[1])).toBe("<title>A&lt;B</title>");
    expect(serialize(root.children[2])).toBe("<rect/>");
  });

  test("attribute whitespace normalization", () => {
    const root = parseSVG(`<svg d="M0\t0\nL1 1"/>`)!;
    expect(root.attrs.d).toBe("M0 0 L1 1");
  });

  test("malformed → null", () => {
    expect(parseSVG("<svg><g></svg>")).toBeNull();
    expect(parseSVG("<svg a=1/>")).toBeNull();
    expect(parseSVG("<svg>&nbsp;</svg>")).toBeNull();
    expect(parseSVG("")).toBeNull();
  });

  test("isolate keeps parent chain + all defs", () => {
    const root = parseSVG(`<svg viewBox="0 0 10 10"><defs><filter id="f"/></defs><g id="a" transform="x"><g id="b"><rect filter="url(#f)" x="1"/></g></g><circle/></svg>`)!;
    const nodes = rasterNodes(root, (n) => n.attrs.filter !== undefined);
    expect(nodes.length).toBe(1);
    expect(isolate(nodes[0], root)).toBe(
      `<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><defs><filter id="f"/></defs><g id="a" transform="x"><g id="b"><rect filter="url(#f)" x="1"/></g></g></svg>`,
    );
  });
});

describe("parsePath", () => {
  test("trailing numbers after Z do not hang", () => {
    const r = parsePath("M0 0 L1 1 Z 5 5");
    expect(r.subpaths.length).toBe(1);
    expect(r.subpaths[0].closed).toBe(true);
  });
});
