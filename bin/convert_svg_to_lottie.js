#!/usr/bin/env node

/**
 * SVG Path → Lottie JSON Converter
 *
 * Парсит SVG path d="..." строку и генерирует точный Lottie JSON
 * с правильными relative bezier handles (i/o tangents).
 *
 * Поддерживаемые команды: M, m, C, c, S, s, L, l, H, h, V, v, Z, z
 *
 * Использование:
 *   node bin/convert_svg_to_lottie.js '<svg path d string>' [--width 24] [--height 24] [--stroke-width 2]
 *   echo '<svg path d string>' | node bin/convert_svg_to_lottie.js
 *   node bin/convert_svg_to_lottie.js --shapes-only '<svg path d string>'
 */

// ---- Tokenizer ----
function tokenize(d) {
  return d.match(/[MmCcSsLlHhVvQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || [];
}

// ---- SVG Path Parser ----
function parseSVGPath(d) {
  const tokens = tokenize(d);
  const subpaths = [];
  let current = null;
  let x = 0, y = 0;
  let i = 0;

  function num() { return parseFloat(tokens[i++]); }
  function isNum() { return i < tokens.length && /[-+\d.]/.test(tokens[i]); }

  function newSubpath(px, py) {
    current = { vertices: [], inTangents: [], outTangents: [], closed: false };
    current.vertices.push([px, py]);
    current.inTangents.push([0, 0]);
    current.outTangents.push([0, 0]);
    subpaths.push(current);
  }

  function addCurve(cp1x, cp1y, cp2x, cp2y, ex, ey) {
    // out-tangent предыдущей вершины = cp1 - prevVertex
    current.outTangents[current.outTangents.length - 1] = [cp1x - x, cp1y - y];
    x = ex; y = ey;
    current.vertices.push([x, y]);
    // in-tangent текущей вершины = cp2 - currentVertex
    current.inTangents.push([cp2x - x, cp2y - y]);
    current.outTangents.push([0, 0]);
  }

  function addLine(ex, ey) {
    current.outTangents[current.outTangents.length - 1] = [0, 0];
    x = ex; y = ey;
    current.vertices.push([x, y]);
    current.inTangents.push([0, 0]);
    current.outTangents.push([0, 0]);
  }

  while (i < tokens.length) {
    const cmd = tokens[i];
    if (!/[A-Za-z]/.test(cmd)) { i++; continue; }
    i++;

    switch (cmd) {
      case 'M':
        x = num(); y = num();
        newSubpath(x, y);
        while (isNum()) { addLine(num(), num()); }
        break;
      case 'm':
        x += num(); y += num();
        newSubpath(x, y);
        while (isNum()) { const dx = num(), dy = num(); addLine(x + dx, y + dy); }
        break;
      case 'C':
        while (isNum()) { addCurve(num(), num(), num(), num(), num(), num()); }
        break;
      case 'c':
        while (isNum()) {
          const c1x = x + num(), c1y = y + num();
          const c2x = x + num(), c2y = y + num();
          const ex = x + num(), ey = y + num();
          addCurve(c1x, c1y, c2x, c2y, ex, ey);
        }
        break;
      case 'S':
        while (isNum()) {
          const prevIn = current.inTangents[current.inTangents.length - 1];
          const cp1x = x - prevIn[0], cp1y = y - prevIn[1];
          addCurve(cp1x, cp1y, num(), num(), num(), num());
        }
        break;
      case 's':
        while (isNum()) {
          const prevIn = current.inTangents[current.inTangents.length - 1];
          const cp1x = x - prevIn[0], cp1y = y - prevIn[1];
          const c2x = x + num(), c2y = y + num();
          const ex = x + num(), ey = y + num();
          addCurve(cp1x, cp1y, c2x, c2y, ex, ey);
        }
        break;
      case 'L':
        while (isNum()) { addLine(num(), num()); }
        break;
      case 'l':
        while (isNum()) { addLine(x + num(), y + num()); }
        break;
      case 'H':
        while (isNum()) { addLine(num(), y); }
        break;
      case 'h':
        while (isNum()) { addLine(x + num(), y); }
        break;
      case 'V':
        while (isNum()) { addLine(x, num()); }
        break;
      case 'v':
        while (isNum()) { addLine(x, y + num()); }
        break;
      case 'Z':
      case 'z':
        if (current) {
          current.closed = true;
          const first = current.vertices[0];
          const last = current.vertices[current.vertices.length - 1];
          if (Math.abs(first[0] - last[0]) < 0.001 && Math.abs(first[1] - last[1]) < 0.001) {
            current.inTangents[0] = current.inTangents[current.inTangents.length - 1];
            current.vertices.pop();
            current.inTangents.pop();
            current.outTangents.pop();
          }
          x = first[0]; y = first[1];
        }
        break;
    }
  }

  return subpaths;
}

// ---- Lottie JSON Builder ----
function r(n) { return Math.round(n * 10000) / 10000; }

function subpathToShape(sp, name, index) {
  return {
    ind: index,
    ty: "sh",
    ix: index + 1,
    ks: {
      a: 0,
      k: {
        v: sp.vertices.map(p => [r(p[0]), r(p[1])]),
        i: sp.inTangents.map(p => [r(p[0]), r(p[1])]),
        o: sp.outTangents.map(p => [r(p[0]), r(p[1])]),
        c: sp.closed
      },
      ix: 2
    },
    nm: name,
    mn: "ADBE Vector Shape - Group"
  };
}

function svgPathToLottie(d, opts = {}) {
  const w = opts.w || 24;
  const h = opts.h || 24;
  const sw = opts.strokeWidth || 2;
  const strokeColor = opts.strokeColor || [0, 0, 0, 1];
  const fr = opts.fr || 24;

  const subpaths = parseSVGPath(d);
  const shapes = subpaths.map((sp, i) => subpathToShape(sp, "Path " + (i + 1), i));

  return {
    v: "5.5.2",
    fr: fr,
    ip: 0,
    op: fr,
    w: w,
    h: h,
    nm: "SVG to Lottie",
    ddd: 0,
    assets: [],
    markers: [],
    layers: [{
      ddd: 0, ind: 0, ty: 4, nm: "Shape", sr: 1,
      ks: {
        o: { a: 0, k: 100, ix: 11 },
        r: { a: 0, k: 0, ix: 10 },
        p: { a: 0, k: [w / 2, h / 2, 0], ix: 2 },
        a: { a: 0, k: [w / 2, h / 2, 0], ix: 1 },
        s: { a: 0, k: [100, 100, 100], ix: 6 }
      },
      ao: 0,
      shapes: [{
        ty: "gr",
        it: [
          ...shapes,
          {
            ty: "st",
            c: { a: 0, k: strokeColor, ix: 3 },
            o: { a: 0, k: 100, ix: 4 },
            w: { a: 0, k: sw, ix: 5 },
            lc: 2, lj: 2, bm: 0,
            nm: "Stroke", mn: "ADBE Vector Graphic - Stroke"
          },
          {
            ty: "tr",
            p: { a: 0, k: [0, 0], ix: 2 },
            a: { a: 0, k: [0, 0], ix: 1 },
            s: { a: 0, k: [100, 100], ix: 3 },
            r: { a: 0, k: 0, ix: 6 },
            o: { a: 0, k: 100, ix: 7 },
            sk: { a: 0, k: 0, ix: 4 },
            sa: { a: 0, k: 0, ix: 5 },
            nm: "Transform"
          }
        ],
        nm: "Group", np: shapes.length + 1, cix: 2, bm: 0, ix: 1,
        mn: "ADBE Vector Group"
      }],
      ip: 0, op: fr, st: 0, bm: 0
    }]
  };
}

// ---- Утилита: только парсинг без обёртки ----
function svgPathToLottieShapes(d) {
  const subpaths = parseSVGPath(d);
  return subpaths.map((sp, i) => ({
    name: "Path " + (i + 1),
    vertices: sp.vertices.length,
    closed: sp.closed,
    shape: {
      v: sp.vertices.map(p => [r(p[0]), r(p[1])]),
      i: sp.inTangents.map(p => [r(p[0]), r(p[1])]),
      o: sp.outTangents.map(p => [r(p[0]), r(p[1])]),
      c: sp.closed
    }
  }));
}

// ---- CLI ----
function printUsage() {
  console.error(`Usage:
  node bin/convert_svg_to_lottie.js '<path d>' [options]
  echo '<path d>' | node bin/convert_svg_to_lottie.js [options]

Options:
  --width, -w        Width (default: 24)
  --height, -h       Height (default: 24)
  --stroke-width     Stroke width (default: 2)
  --shapes-only      Output only shapes (no full Lottie wrapper)
  --pretty           Pretty-print JSON output
  --help             Show this help`);
}

function parseArgs(argv) {
  const opts = { w: 24, h: 24, strokeWidth: 2, shapesOnly: false, pretty: false };
  let pathD = null;
  let i = 0;

  while (i < argv.length) {
    const arg = argv[i];
    switch (arg) {
      case '--width': case '-w':
        opts.w = parseInt(argv[++i], 10); break;
      case '--height':
        opts.h = parseInt(argv[++i], 10); break;
      case '--stroke-width':
        opts.strokeWidth = parseFloat(argv[++i]); break;
      case '--shapes-only':
        opts.shapesOnly = true; break;
      case '--pretty':
        opts.pretty = true; break;
      case '--help':
        printUsage(); process.exit(0);
      default:
        if (!arg.startsWith('-')) pathD = arg;
        break;
    }
    i++;
  }

  return { pathD, opts };
}

function main() {
  const { pathD: argPath, opts } = parseArgs(process.argv.slice(2));

  if (argPath) {
    output(argPath, opts);
  } else if (!process.stdin.isTTY) {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => data += chunk);
    process.stdin.on('end', () => {
      const d = data.trim();
      if (!d) { printUsage(); process.exit(1); }
      output(d, opts);
    });
  } else {
    printUsage();
    process.exit(1);
  }
}

function output(d, opts) {
  const indent = opts.pretty ? 2 : undefined;
  if (opts.shapesOnly) {
    console.log(JSON.stringify(svgPathToLottieShapes(d), null, indent));
  } else {
    console.log(JSON.stringify(svgPathToLottie(d, opts), null, indent));
  }
}

// ---- Exports (для использования как модуль) ----
module.exports = { svgPathToLottie, svgPathToLottieShapes, parseSVGPath };

main();
