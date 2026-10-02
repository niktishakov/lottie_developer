import Foundation

enum RequestKind { case mcp, viewer }

/// Маршрутизация запросов к серверу на iPhone:
/// - `/mcp` — MCP по Streamable HTTP для Claude Code на ПК;
/// - `/`, `/p/<id>`, `/lottie.js`, `/api/...` — просмотрщик для браузера ПК (тот же API, что у web/src/server/http.ts);
/// - `/pair` — сопряжение браузера по PIN с экрана iPhone.
final class CompanionRoutes: @unchecked Sendable {
    private let store: ProjectStore
    private let mcp: MCPServer
    private let auth: PairingAuth
    private let onRequest: @Sendable (RequestKind) -> Void

    init(store: ProjectStore, mcp: MCPServer, auth: PairingAuth, onRequest: @escaping @Sendable (RequestKind) -> Void) {
        self.store = store
        self.mcp = mcp
        self.auth = auth
        self.onRequest = onRequest
    }

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        await route(req)
    }

    // MARK: - Routing

    @MainActor
    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        let p = req.path
        let method = req.method.uppercased()

        // Сопряжение — без токена.
        if p == "/pair" {
            if method == "POST" { return pair(req) }
            return .text(Self.pairHTML, contentType: "text/html; charset=utf-8")
        }
        if p == "/favicon.ico" { return HTTPResponse(status: 204, headers: [:], body: Data()) }

        if !isAuthorized(req) {
            if p == "/mcp" {
                var r = HTTPResponse.json(["error": "Unauthorized: add the Authorization header from the iPhone app"], status: 401)
                r.headers["WWW-Authenticate"] = "Bearer"
                return r
            }
            if method == "GET", p == "/" || p.hasPrefix("/p/") {
                return HTTPResponse(status: 302, headers: ["Location": "/pair"], body: Data())
            }
            return .json(["error": "Unauthorized: pair this browser at /pair"], status: 401)
        }

        if p == "/mcp" {
            onRequest(.mcp)
            return await handleMCP(req)
        }

        onRequest(.viewer)
        return await viewer(req, path: p, method: method)
    }

    // MARK: - Auth

    @MainActor
    private func isAuthorized(_ req: HTTPRequest) -> Bool {
        if Self.isLocal(req.remoteIP) { return true }
        if let a = req.headers["authorization"] {
            let parts = a.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "bearer", auth.isValid(token: parts[1].trimmingCharacters(in: .whitespaces)) { return true }
        }
        if auth.isValid(token: req.query["token"]) { return true }
        if auth.isValid(token: req.headers["x-lottie-token"]) { return true }
        if auth.isValid(token: Self.cookie("lottie_token", in: req.headers["cookie"])) { return true }
        return false
    }

    private static func isLocal(_ ip: String) -> Bool {
        var s = ip.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") , let end = s.firstIndex(of: "]") { s = String(s[s.index(after: s.startIndex)..<end]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        // "127.0.0.1:5000" → "127.0.0.1" (IPv4 с портом)
        if s.filter({ $0 == ":" }).count == 1, let c = s.firstIndex(of: ":") { s = String(s[..<c]) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s == "127.0.0.1" || s == "::1" || s == "localhost"
    }

    private static func cookie(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    @MainActor
    private func pair(_ req: HTTPRequest) -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        let pin: String = {
            if let s = body?["pin"] as? String { return s }
            if let n = body?["pin"] as? Int { return String(format: "%06d", n) }
            return ""
        }()
        switch auth.verify(pin: pin) {
        case .rateLimited:
            return .json(["error": "Too many attempts. Wait a minute and try again."], status: 429)
        case .wrong:
            return .json(["error": "Wrong PIN"], status: 403)
        case .ok:
            let host = req.headers["host"] ?? "<iphone-ip>:\(CompanionServer.port)"
            let token = auth.token
            let cmd = "claude mcp add -s user --transport http lottie-developer http://\(host)/mcp --header \"Authorization: Bearer \(token)\""
            var r = HTTPResponse.json(["token": token, "mcpCommand": cmd])
            r.headers["Set-Cookie"] = "lottie_token=\(token); Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly"
            return r
        }
    }

    // MARK: - MCP (Streamable HTTP)

    @MainActor
    private func handleMCP(_ req: HTTPRequest) async -> HTTPResponse {
        switch req.method.uppercased() {
        case "GET":
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"], body: Data())
        case "DELETE":
            return HTTPResponse(status: 200, headers: [:], body: Data())
        case "POST":
            break
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"], body: Data())
        }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) else {
            return .json(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]], status: 400)
        }
        let isBatch = obj is [Any]
        let messages: [[String: Any]] = isBatch ? ((obj as? [Any]) ?? []).compactMap { $0 as? [String: Any] } : [obj as? [String: Any] ?? [:]]
        var replies: [[String: Any]] = []
        var initialize = false
        for m in messages {
            if m["method"] as? String == "initialize" { initialize = true }
            if let r = await mcp.handle(m) { replies.append(r) }
        }
        var resp: HTTPResponse
        if replies.isEmpty {
            resp = HTTPResponse(status: 202, headers: [:], body: Data())
        } else if isBatch {
            resp = .json(replies)
        } else {
            resp = .json(replies[0])
        }
        if initialize {
            resp.headers["Mcp-Session-Id"] = UUID().uuidString
        } else if let sid = req.headers["mcp-session-id"] {
            resp.headers["Mcp-Session-Id"] = sid
        }
        return resp
    }

    /// Вызов MCP-инструмента тем же кодом, что у Claude: ошибка → 400 {error}.
    @MainActor
    private func act(_ name: String, _ args: [String: Any]) async -> HTTPResponse {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let r = await mcp.handle(msg)
        guard let result = r?["result"] as? [String: Any] else {
            let err = (r?["error"] as? [String: Any])?["message"] as? String
            return .json(["error": err ?? "MCP call failed"], status: 400)
        }
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if result["isError"] as? Bool == true {
            let m = text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
            return .json(["error": m], status: 400)
        }
        if let d = text.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
            if v is [String: Any] || v is [Any] { return .json(v) }
            return .json(["result": v])
        }
        return .json(["result": text])
    }

    // MARK: - Viewer API

    @MainActor
    private func viewer(_ req: HTTPRequest, path p: String, method: String) async -> HTTPResponse {
        if p == "/" || p.hasPrefix("/p/") {
            guard let d = Self.resource("index.html") else { return .text("Viewer not bundled", status: 500) }
            return .data(d, contentType: "text/html; charset=utf-8")
        }
        if p == "/lottie.js" {
            guard let d = Self.resource("lottie.js") else { return .text("lottie.js not bundled", status: 404) }
            return .data(d, contentType: "text/javascript")
        }
        // QR-код для «Connect iPhone» на iPhone не нужен: пустой скрипт, чтобы страница не падала.
        if p == "/qrcode.js" {
            return .data(Data("window.qrcode = window.qrcode || null;".utf8), contentType: "text/javascript")
        }
        if p == "/api/device/status" { return .json(["devices": [Any]()]) }
        if p == "/api/device/pair" {
            return .json(["token": auth.token, "port": Int(CompanionServer.port), "hosts": [String](), "devices": [Any](), "links": [String]()])
        }

        store.reloadIfChanged()

        // Файл с ПК → во «входящие» на iPhone. Claude на Windows: curl.exe -T file "http://<iphone>:8765/api/upload?name=file.zip" -H "Authorization: Bearer <token>"
        // Ответ — путь на iPhone, его передают в create_project(bundle:/svg_path:/images:) или add_assets(paths:).
        if p == "/api/upload", method == "POST" || method == "PUT" {
            let raw = (req.query["name"] ?? "upload").removingPercentEncoding ?? "upload"
            let name = (raw as NSString).lastPathComponent.replacingOccurrences(of: "..", with: "_")
            let inbox = store.rootDir.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            var dst = inbox.appendingPathComponent(name.isEmpty ? "upload" : name)
            if FileManager.default.fileExists(atPath: dst.path) {
                dst = inbox.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(dst.lastPathComponent)")
            }
            do { try req.body.write(to: dst) } catch { return .json(["error": error.localizedDescription], status: 500) }
            return .json(["path": dst.path, "bytes": req.body.count,
                          "next": "Pass this path to create_project(bundle: path) for a zip/folder, svg_path / lottie_path / images, or add_assets(paths: [path])."])
        }
        // Скачать файл с iPhone на ПК (например, экспортированный JSON). Только внутри контейнера приложения.
        if p == "/api/file" {
            let path = (req.query["path"] ?? "").removingPercentEncoding ?? ""
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(home), let data = try? Data(contentsOf: url) else { return .json(["error": "not found"], status: 404) }
            return .data(data, contentType: url.pathExtension == "json" ? "application/json" : "application/octet-stream")
        }
        if p == "/api/poll" {
            return .json(["sig": signature(), "command": rawJSON(store.uiCommandURL) ?? NSNull()])
        }
        if p == "/api/projects" {
            return encoded(store.projects)
        }
        if p == "/api/state", method == "POST" {
            guard var st = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
                return .json(["error": "bad json"], status: 400)
            }
            st["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            if let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? d.write(to: store.appStateURL, options: .atomic)
            }
            return .json(["ok": true])
        }

        let parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // api / project / <id> [/ sub [/ vid]]
        guard parts.count >= 3, parts[0] == "api", parts[1] == "project" else {
            return .text("Not found", status: 404)
        }
        guard let pid = UUID(uuidString: parts[2]), let proj = store.project(pid) else {
            return .json(["error": "not found"], status: 404)
        }
        let id = proj.id

        if parts.count == 3 { return encoded(proj) }
        let sub = parts[3]

        switch (sub, parts.count) {
        case ("geometry", 4):
            guard let d = store.geometryData(for: proj) else { return .json(["error": "no geometry"], status: 404) }
            return .data(d, contentType: "application/json")

        case ("version", 5):
            guard let vid = UUID(uuidString: parts[4]), let v = proj.versions.first(where: { $0.id == vid }),
                  let d = try? Data(contentsOf: store.versionURL(id, v.compiledFile)) else {
                return .json(["error": "no version"], status: 404)
            }
            return .data(d, contentType: "application/json")

        case ("assets", 4):
            let usage = AssetFiles.usage(store.assetsDir(id))
            let names = Set(proj.layerNames)
            let list: [[String: Any]] = store.assets(projectID: id).map { f in
                var pixels: Any = NSNull()
                if f.kind == "image", let d = try? Data(contentsOf: f.url), let px = LottieImageLayers.pixelSize(d) {
                    pixels = ["width": px.width, "height": px.height]
                }
                return ["name": f.name, "path": f.url.path, "bytes": f.bytes, "kind": f.kind,
                        "modified": (f.modified.timeIntervalSince1970 * 1000).rounded(),
                        "usedBy": (usage[f.name] ?? []).filter { names.contains($0) }, "pixels": pixels]
            }
            return .json(list)

        case ("asset", 4):
            let name = Self.param(req, "name")
            if method == "DELETE" { return await act("delete_asset", ["project_id": id.uuidString, "name": name]) }
            guard !name.isEmpty, !name.contains("/"), let f = store.assets(projectID: id).first(where: { $0.name == name }),
                  let d = try? Data(contentsOf: f.url) else {
                return .json(["error": "no asset"], status: 404)
            }
            return .data(d, contentType: Self.mime[f.url.pathExtension.lowercased()] ?? "application/octet-stream")

        case ("upload", 4):
            let raw = Self.param(req, "name")
            let name = (raw as NSString).lastPathComponent.isEmpty ? "file" : (raw as NSString).lastPathComponent
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("upload_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let file = tmpDir.appendingPathComponent(name)
                try req.body.write(to: file)
                let added = try store.addAssets(projectID: id, [file])
                return .json(["added": added])
            } catch {
                return .json(["error": error.localizedDescription], status: 400)
            }

        case ("place", 4):
            var args = bodyJSON(req)
            args["project_id"] = id.uuidString
            return await act("place_asset", args)

        case ("edits", 4):
            let b = bodyJSON(req)
            var args: [String: Any] = ["project_id": id.uuidString, "overrides": b["overrides"] ?? [String: Any](),
                                       "prompt": "Edits in viewer", "show_in_app": false]
            if let v = b["version"], !(v is NSNull) { args["version"] = v }
            if let n = b["note"], !(n is NSNull) { args["note"] = n }
            return await act("apply_overrides", args)

        case ("feedback", 4):
            if method == "GET" { return encoded(store.feedback(projectID: id)) }
            let b = bodyJSON(req)
            let item = FeedbackItem(versionID: (b["versionID"] as? String).flatMap(UUID.init(uuidString:)),
                                    versionLabel: b["versionLabel"] as? String ?? "geometry",
                                    frame: Int(((b["frame"] as? NSNumber)?.doubleValue ?? 0).rounded()),
                                    layer: b["layer"] as? String,
                                    text: String(describing: b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            store.addFeedback(projectID: id, item)
            return .json(["ok": true])

        case ("feedback-resolve", 4):
            let b = bodyJSON(req)
            guard let fid = (b["id"] as? String).flatMap(UUID.init(uuidString:)) else { return .json(["ok": false]) }
            let r = store.resolveFeedback(projectID: id, id: fid, reply: nil, resolved: b["resolved"] as? Bool ?? false)
            return .json(["ok": r != nil])

        case ("feedback-delete", 4):
            let b = bodyJSON(req)
            if let fid = (b["id"] as? String).flatMap(UUID.init(uuidString:)) { store.deleteFeedback(projectID: id, id: fid) }
            return .json(["ok": true])

        default:
            return .text("Not found", status: 404)
        }
    }

    // MARK: - Helpers

    private static let mime: [String: String] = ["svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                                 "webp": "image/webp", "heic": "image/heic", "json": "application/json"]

    private static func param(_ req: HTTPRequest, _ key: String) -> String {
        let v = req.query[key] ?? ""
        if v.contains("%"), let d = v.removingPercentEncoding { return d }
        return v
    }

    private func bodyJSON(_ req: HTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
    }

    private func rawJSON(_ url: URL) -> Any? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// Как пишет Mac-приложение: ISO-даты, отсортированные ключи.
    private func encoded<T: Encodable>(_ value: T) -> HTTPResponse {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(value) else { return .json(["error": "encode failed"], status: 500) }
        return .data(d, contentType: "application/json")
    }

    /// Подпись состояния диска: меняется, когда MCP или приложение что-то записали.
    @MainActor
    private func signature() -> String {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: store.rootDir, includingPropertiesForKeys: nil) else { return "" }
        var parts: [String] = []
        for dir in dirs where dir.hasDirectoryPath {
            for f in ["project.json", "feedback.json", "assets"] {
                let u = dir.appendingPathComponent(f)
                if let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date {
                    parts.append("\(dir.lastPathComponent)/\(f):\(m.timeIntervalSince1970)")
                }
            }
        }
        // Стабильный хеш (FNV-1a), без зависимости от Hasher seed.
        var h: UInt64 = 0xcbf29ce484222325
        for b in parts.sorted().joined(separator: "|").utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h)
    }

    private static let viewerDir: URL? = Bundle.main.url(forResource: "viewer", withExtension: nil)
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    private static func resource(_ name: String) -> Data? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let d = cache[name] { return d }
        let url = viewerDir?.appendingPathComponent(name)
            ?? Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension)
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        cache[name] = d
        return d
    }

    // MARK: - Pair page

    private static let pairHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Pair with iPhone</title>
    <style>
      :root { color-scheme: light dark; --bg:#f5f5f7; --fg:#1d1d1f; --card:#fff; --muted:#6e6e73; --accent:#0a84ff; --err:#d70015; }
      @media (prefers-color-scheme: dark) { :root { --bg:#111; --fg:#f5f5f7; --card:#1c1c1e; --muted:#98989d; --err:#ff453a; } }
      body { margin:0; font:15px/1.45 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--fg);
             display:flex; min-height:100vh; align-items:center; justify-content:center; padding:16px; box-sizing:border-box; }
      .card { background:var(--card); border-radius:14px; padding:28px; max-width:560px; width:100%; box-shadow:0 4px 24px rgba(0,0,0,.08); }
      h1 { margin:0 0 6px; font-size:22px; } p { margin:6px 0 16px; color:var(--muted); }
      input { font:600 28px ui-monospace,Consolas,monospace; letter-spacing:8px; width:100%; box-sizing:border-box; padding:10px 14px;
              border:1px solid #8884; border-radius:10px; background:transparent; color:var(--fg); text-align:center; }
      button, a.btn { font:600 15px inherit; border:0; border-radius:10px; padding:10px 18px; background:var(--accent); color:#fff;
              cursor:pointer; text-decoration:none; display:inline-block; margin-top:12px; }
      textarea { width:100%; box-sizing:border-box; font:13px ui-monospace,Consolas,monospace; padding:10px; border-radius:10px;
                 border:1px solid #8884; background:transparent; color:var(--fg); resize:none; height:96px; }
      .err { color:var(--err); min-height:1.4em; margin-top:8px; } .hidden { display:none; } .row { display:flex; gap:10px; flex-wrap:wrap; }
    </style></head><body>
    <div class="card">
      <div id="step1">
        <h1>Pair with iPhone</h1>
        <p>Enter the 6-digit PIN shown in Lottie Developer on your iPhone.</p>
        <form id="f"><input id="pin" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000" autofocus>
        <button type="submit">Pair</button></form>
        <div class="err" id="err"></div>
      </div>
      <div id="step2" class="hidden">
        <h1>Paired</h1>
        <p>Run this command once in a terminal to connect Claude Code to the iPhone:</p>
        <textarea id="cmd" readonly></textarea>
        <div class="row"><button id="copy" type="button">Copy</button><a class="btn" href="/">Open viewer</a></div>
      </div>
    </div>
    <script>
    const $ = (id) => document.getElementById(id);
    $("f").onsubmit = async (e) => {
      e.preventDefault(); $("err").textContent = "";
      try {
        const r = await fetch("/pair", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ pin: $("pin").value.trim() }) });
        const j = await r.json();
        if (!r.ok) { $("err").textContent = j.error || "Pairing failed"; return; }
        $("cmd").value = j.mcpCommand; $("step1").classList.add("hidden"); $("step2").classList.remove("hidden");
      } catch (err) { $("err").textContent = "Cannot reach the iPhone: " + err; }
    };
    $("copy").onclick = async () => {
      const t = $("cmd");
      try { await navigator.clipboard.writeText(t.value); } catch { t.select(); document.execCommand("copy"); }
      $("copy").textContent = "Copied";
      setTimeout(() => $("copy").textContent = "Copy", 1500);
    };
    </script></body></html>
    """
}

// MARK: - Pairing

/// Сопряжение ПК с iPhone: постоянный токен (UserDefaults) + PIN из 6 цифр (новый при каждом запуске).
@MainActor
final class PairingAuth {
    private static let tokenKey = "companion.pairingToken"

    var token: String
    var pin: String

    /// Время неверных попыток PIN (для лимита 5 в минуту).
    private var failures: [Date] = []
    static let maxFailuresPerMinute = 5

    init() {
        if let t = UserDefaults.standard.string(forKey: Self.tokenKey), t.count == 32 {
            token = t
        } else {
            token = Self.randomHex(16)
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
        }
        pin = Self.randomPIN()
    }

    /// Новый токен: все сопряжённые ПК придётся сопрягать заново.
    func resetToken() {
        token = Self.randomHex(16)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    func regeneratePIN() { pin = Self.randomPIN() }

    func isValid(token t: String?) -> Bool {
        guard let t, !t.isEmpty else { return false }
        return Self.constantTimeEqual(t, token)
    }

    enum PINResult { case ok, wrong, rateLimited }

    func verify(pin p: String) -> PINResult {
        let now = Date()
        failures.removeAll { now.timeIntervalSince($0) > 60 }
        if failures.count >= Self.maxFailuresPerMinute { return .rateLimited }
        if Self.constantTimeEqual(p.trimmingCharacters(in: .whitespacesAndNewlines), pin) { return .ok }
        failures.append(now)
        return .wrong
    }

    // MARK: - Helpers

    private static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    private static func randomPIN() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &g))
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
