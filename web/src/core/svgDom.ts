// Минимальное DOM-дерево SVG — порт Sources/Shared/SVGDocument.swift (parse / rasterNodes / isolate).
// Свой небольшой XML-парсер: XML-декларация, комментарии, CDATA, DOCTYPE (с внутренними <!ENTITY>),
// самозакрывающиеся теги, сущности. Поведение подогнано под Foundation XMLParser (libxml2):
// - имена тегов/атрибутов как в исходнике (с префиксами: `xlink:href`);
// - значения атрибутов нормализуются (литеральные \t \n \r → пробел), сущности раскрываются;
// - текст приходит кусками (сущность — отдельный кусок), каждый кусок обрезается по пробелам;
// - CDATA в текст узла не попадает (XMLParser отдаёт его через foundCDATA, Builder его не слушает).

export interface SVGNode {
  tag: string;
  attrs: Record<string, string>;
  children: SVGNode[];
  text: string;
  parent: SVGNode | null;
}

/** Теги, содержимое которых не рисуется напрямую. */
export const nonRendered: ReadonlySet<string> = new Set([
  "defs", "clippath", "mask", "symbol", "pattern", "marker", "lineargradient", "radialgradient", "filter",
]);

class XMLError extends Error {}

const PREDEFINED: Record<string, string> = { lt: "<", gt: ">", amp: "&", quot: "\"", apos: "'" };
const NAME_RE = /^[^\s/>=<"'!?]+/;

function escape(s: string): string {
  return s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("\"", "&quot;");
}

function sortedKeys(attrs: Record<string, string>): string[] {
  return Object.keys(attrs).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

export function serialize(n: SVGNode): string {
  const a = sortedKeys(n.attrs).map((k) => ` ${k}="${escape(n.attrs[k])}"`).join("");
  if (n.children.length === 0 && n.text === "") return `<${n.tag}${a}/>`;
  return `<${n.tag}${a}>${escape(n.text)}${n.children.map(serialize).join("")}</${n.tag}>`;
}

/** Разбор SVG/XML. null — документ не well-formed (как XMLParser.parse() == false). */
export function parseSVG(text: string): SVGNode | null {
  try {
    return new Parser(text).parse();
  } catch (e) {
    if (e instanceof XMLError) return null;
    throw e;
  }
}

/** Узлы, которые придётся растеризовать (по порядку документа, без вложенных друг в друга). */
export function rasterNodes(root: SVGNode, needsRaster: (n: SVGNode) => boolean): SVGNode[] {
  const out: SVGNode[] = [];
  const walk = (n: SVGNode) => {
    if (nonRendered.has(n.tag.toLowerCase())) return;
    if (n !== root && needsRaster(n)) { out.push(n); return; }
    n.children.forEach(walk);
  };
  walk(root);
  return out;
}

function collectDefs(n: SVGNode): SVGNode[] {
  const out: SVGNode[] = [];
  for (const c of n.children) {
    const t = c.tag.toLowerCase();
    if (t === "defs" || t === "lineargradient" || t === "radialgradient" || t === "filter" || t === "clippath" || t === "mask") {
      out.push(c);
    } else {
      out.push(...collectDefs(c));
    }
  }
  return out;
}

/** SVG-документ, в котором видим только `node` (с цепочкой родительских узлов и всеми defs). */
export function isolate(node: SVGNode, root: SVGNode): string {
  const chain: SVGNode[] = [];
  let cur = node.parent;
  while (cur && cur !== root) { chain.unshift(cur); cur = cur.parent; }
  let inner = serialize(node);
  for (const g of [...chain].reverse()) {
    const a = sortedKeys(g.attrs).map((k) => ` ${k}="${g.attrs[k]}"`).join("");
    inner = `<${g.tag}${a}>${inner}</${g.tag}>`;
  }
  const defs = collectDefs(root).map(serialize).join("");
  const rootAttrs: Record<string, string> = { ...root.attrs };
  if (rootAttrs["xmlns"] === undefined) rootAttrs["xmlns"] = "http://www.w3.org/2000/svg";
  const a = sortedKeys(rootAttrs).map((k) => ` ${k}="${rootAttrs[k]}"`).join("");
  return `<svg${a}>${defs}${inner}</svg>`;
}

// MARK: - XML parser

class Parser {
  private s: string;
  private i = 0;
  private entities: Record<string, string> = Object.assign(Object.create(null), PREDEFINED);
  private root: SVGNode | null = null;
  private stack: SVGNode[] = [];

  constructor(text: string) {
    // Переводы строк по XML-спеке: \r\n и \r → \n.
    this.s = text.replace(/^﻿/, "").replace(/\r\n?/g, "\n");
  }

  parse(): SVGNode {
    const s = this.s;
    while (this.i < s.length) {
      if (s.startsWith("<?", this.i)) this.skipTo("?>");
      else if (s.startsWith("<!--", this.i)) this.skipTo("-->");
      else if (s.startsWith("<![CDATA[", this.i)) {
        if (this.stack.length === 0) throw new XMLError("CDATA outside root");
        this.skipTo("]]>");
      } else if (s.startsWith("<!DOCTYPE", this.i)) this.doctype();
      else if (s.startsWith("</", this.i)) this.endTag();
      else if (s[this.i] === "<") this.startTag();
      else this.textRun();
    }
    if (!this.root || this.stack.length > 0) throw new XMLError("unexpected end of document");
    return this.root;
  }

  private skipTo(end: string) {
    const j = this.s.indexOf(end, this.i);
    if (j < 0) throw new XMLError(`missing ${end}`);
    this.i = j + end.length;
  }

  private doctype() {
    const s = this.s;
    let j = this.i + 9;
    let depth = 0;
    let quote = "";
    const start = j;
    for (; j < s.length; j++) {
      const c = s[j];
      if (quote) { if (c === quote) quote = ""; continue; }
      if (c === "\"" || c === "'") quote = c;
      else if (c === "[") depth++;
      else if (c === "]") depth--;
      else if (c === ">" && depth <= 0) break;
    }
    if (j >= s.length) throw new XMLError("unterminated DOCTYPE");
    const body = s.slice(start, j);
    const re = /<!ENTITY\s+([^\s%]+)\s+(?:"([^"]*)"|'([^']*)')\s*>/g;
    for (let m; (m = re.exec(body)); ) this.entities[m[1]] = m[2] ?? m[3] ?? "";
    this.i = j + 1;
  }

  /** Сущность в позиции i (на '&'): значение и длина ссылки. */
  private entity(i: number): [string, number] {
    const s = this.s;
    const semi = s.indexOf(";", i);
    if (semi < 0) throw new XMLError("bad entity");
    const name = s.slice(i + 1, semi);
    let v: string | undefined;
    if (name.startsWith("#x") || name.startsWith("#X")) {
      if (!/^[0-9a-fA-F]+$/.test(name.slice(2))) throw new XMLError("bad char ref");
      v = String.fromCodePoint(parseInt(name.slice(2), 16));
    } else if (name.startsWith("#")) {
      if (!/^[0-9]+$/.test(name.slice(1))) throw new XMLError("bad char ref");
      v = String.fromCodePoint(parseInt(name.slice(1), 10));
    } else {
      v = this.entities[name];
    }
    if (v === undefined) throw new XMLError(`undefined entity ${name}`);
    return [v, semi + 1 - i];
  }

  private textRun() {
    const s = this.s;
    const end = s.indexOf("<", this.i);
    const stop = end < 0 ? s.length : end;
    const top = this.stack[this.stack.length - 1];
    // Куски как у XMLParser: литеральный текст между сущностями и каждая сущность отдельно.
    let chunk = "";
    const flush = () => {
      const t = chunk.trim();
      if (t !== "") {
        if (!top) throw new XMLError("text outside root");
        top.text += t;
      }
      chunk = "";
    };
    let i = this.i;
    while (i < stop) {
      if (s[i] === "&") {
        flush();
        const [v, len] = this.entity(i);
        chunk = v; flush();
        i += len;
      } else {
        chunk += s[i++];
      }
    }
    flush();
    this.i = stop;
  }

  private endTag() {
    const s = this.s;
    const m = NAME_RE.exec(s.slice(this.i + 2, this.i + 2 + 512));
    if (!m) throw new XMLError("bad end tag");
    const name = m[0];
    let j = this.i + 2 + name.length;
    while (j < s.length && /\s/.test(s[j])) j++;
    if (s[j] !== ">") throw new XMLError("bad end tag");
    const top = this.stack.pop();
    if (!top || top.tag !== name) throw new XMLError(`mismatched </${name}>`);
    this.i = j + 1;
  }

  private startTag() {
    const s = this.s;
    const m = NAME_RE.exec(s.slice(this.i + 1, this.i + 1 + 512));
    if (!m) throw new XMLError("bad tag");
    const tag = m[0];
    let j = this.i + 1 + tag.length;
    const attrs: Record<string, string> = Object.create(null);
    let selfClosing = false;
    for (;;) {
      while (j < s.length && /\s/.test(s[j])) j++;
      if (j >= s.length) throw new XMLError("unterminated tag");
      if (s[j] === ">") { j++; break; }
      if (s.startsWith("/>", j)) { j += 2; selfClosing = true; break; }
      const am = NAME_RE.exec(s.slice(j, j + 512));
      if (!am) throw new XMLError("bad attribute");
      const name = am[0];
      j += name.length;
      while (j < s.length && /\s/.test(s[j])) j++;
      if (s[j] !== "=") throw new XMLError("attribute without value");
      j++;
      while (j < s.length && /\s/.test(s[j])) j++;
      const q = s[j];
      if (q !== "\"" && q !== "'") throw new XMLError("unquoted attribute");
      const close = s.indexOf(q, j + 1);
      if (close < 0) throw new XMLError("unterminated attribute");
      if (name in attrs) throw new XMLError("duplicate attribute");
      attrs[name] = this.attrValue(j + 1, close);
      j = close + 1;
    }
    const node: SVGNode = { tag, attrs: { ...attrs }, children: [], text: "", parent: null };
    const parent = this.stack[this.stack.length - 1] ?? null;
    if (!parent && this.root) throw new XMLError("multiple roots");
    node.parent = parent;
    parent?.children.push(node);
    if (!this.root) this.root = node;
    if (!selfClosing) this.stack.push(node);
    this.i = j;
  }

  private attrValue(from: number, to: number): string {
    const s = this.s;
    let out = "";
    for (let i = from; i < to; ) {
      const c = s[i];
      if (c === "<") throw new XMLError("'<' in attribute");
      if (c === "&") {
        const [v, len] = this.entity(i);
        out += v; i += len;
      } else {
        out += c === "\t" || c === "\n" ? " " : c;
        i++;
      }
    }
    return out;
  }
}
