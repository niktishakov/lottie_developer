// lottie-developer — MCP-сервер (stdio, JSON-RPC, по сообщению на строку) + локальный просмотрщик в браузере.
// Один исполняемый файл: Windows (exe), macOS, Linux.
import { Store } from "./store.ts";
import { Tools, ToolError } from "./mcp.ts";
import { startViewer, viewerURL, openBrowser } from "./http.ts";
import spec from "./tools.json" with { type: "json" };

const log = (m: string) => process.stderr.write(`[lottie-developer] ${m}\n`);
const store = new Store();
const serving = startViewer(store);
const tools = new Tools(store, { url: viewerURL, open: (p?: string) => openBrowser(p) });
log(`storage: ${store.root}; viewer: ${viewerURL()}${serving ? "" : " (served by another instance)"}`);

if (process.argv.includes("--viewer") || process.stdin.isTTY) {
  // Двойной клик по exe (без Claude): открыть просмотрщик и работать, пока окно открыто.
  openBrowser();
  log("Viewer mode. Close this window to stop. Claude connects via: claude mcp add -s user lottie-developer -- <path to this exe>");
} else {
  const send = (o: any) => process.stdout.write(JSON.stringify(o) + "\n");
  async function handle(msg: any) {
    const { id, method, params = {} } = msg;
    if (id === undefined || id === null) return; // нотификация
    const ok = (result: any) => send({ jsonrpc: "2.0", id, result });
    switch (method) {
      case "initialize":
        return ok({ protocolVersion: params.protocolVersion ?? "2025-06-18", capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "lottie-developer", version: "1.0.0" }, instructions: spec.instructions });
      case "ping": return ok({});
      case "tools/list": return ok({ tools: spec.tools });
      case "tools/call":
        try {
          const out = await tools.call(params.name, params.arguments ?? {});
          const content: any[] = [{ type: "text", text: JSON.stringify(out.json, null, 2) }];
          for (const png of out.images ?? []) content.push({ type: "image", data: Buffer.from(png).toString("base64"), mimeType: "image/png" });
          return ok({ content, isError: false });
        } catch (e: any) {
          if (!(e instanceof ToolError)) log(`tool ${params.name} failed: ${e?.stack ?? e}`);
          return ok({ content: [{ type: "text", text: `Error: ${e?.message ?? e}` }], isError: true });
        }
      default: return send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
    }
  }
  // Сообщения обрабатываем по очереди: инструменты пишут на диск.
  let queue: Promise<unknown> = Promise.resolve();
  let buf = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }); continue; }
      queue = queue.then(() => handle(msg)).catch((e) => log(String(e)));
    }
  });
  process.stdin.on("end", () => { queue.then(() => process.exit(0)); });
}
