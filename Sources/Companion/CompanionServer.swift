import Foundation
import Observation

/// Всё серверное на iPhone в одном месте: HTTP-сервер (Network.framework), MCP для Claude, API просмотрщика, сопряжение.
/// UI только читает эти свойства.
@MainActor
@Observable
final class CompanionServer {
    static let port: UInt16 = 8765

    let store: ProjectStore
    let mcp: MCPServer
    let auth: PairingAuth
    private var http: HTTPServer?
    private var routes: CompanionRoutes?
    /// Подключение через посредника в интернете — основной способ для Claude на любом ПК.
    private(set) var relay: RelayClient?

    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var addresses: [String] = []
    /// Когда последний раз обращался Claude (MCP) / браузер.
    private(set) var lastMCPAt: Date?
    private(set) var lastViewerAt: Date?
    /// Последние действия Claude, новые сверху.
    private(set) var activity: [ClaudeActivity] = []

    var pin: String { auth.pin }
    var token: String { auth.token }

    /// Команда, которую дизайнер вставляет в Claude Code на ПК: через посредника, если он подключён, иначе по Wi-Fi.
    var mcpCommand: String { Self.command(mcpURL: mcpURL, token: token) }
    var mcpURL: String {
        if relay?.state == .online, let base = relay?.base { return "\(base)/mcp" }
        return "http://\(addresses.first ?? "<iphone-ip>"):\(Self.port)/mcp"
    }
    var viewerURL: String {
        if relay?.state == .online, let base = relay?.base { return base }
        return "http://\(addresses.first ?? "<iphone-ip>"):\(Self.port)"
    }

    /// Короткий адрес для ПК: только PIN, без адреса айфона.
    var pairURL: String {
        if relay?.state == .online, let host = RelayClient.baseURL.host() { return "\(host)/pair" }
        return "\(viewerURL)/pair"
    }

    static func command(mcpURL: String, token: String) -> String {
        "claude mcp add -s user --transport http lottie-developer \(mcpURL) --header \"Authorization: Bearer \(token)\""
    }

    init() {
        let store = ProjectStore()
        self.store = store
        self.mcp = MCPServer(store: store)
        self.auth = PairingAuth()
    }

    func start() {
        guard http == nil else { return }
        addresses = NetworkAddresses.wifiIPv4()
        let routes = CompanionRoutes(store: store, mcp: mcp, auth: auth) { [weak self] kind in
            Task { @MainActor in
                switch kind {
                case .mcp(let tools):
                    self?.lastMCPAt = Date()
                    for t in tools { self?.record(tool: t) }
                case .viewer:
                    self?.lastViewerAt = Date()
                }
            }
        }
        self.routes = routes
        let server = HTTPServer(port: Self.port) { req in await routes.handle(req) }
        do { try server.start(); http = server; isRunning = true; error = nil }
        catch { self.error = error.localizedDescription; isRunning = false }
        let relay = self.relay ?? RelayClient(handler: { req in await routes.handle(req) },
                                              pin: { [auth] in auth.pin })
        self.relay = relay
        relay.connect()
    }

    func stop() { http?.stop(); http = nil; relay?.disconnect(); relay = nil; isRunning = false }

    /// Приложение свёрнуто — iOS всё равно заморозит соединение; открыто — подключаемся снова.
    func pauseRelay() { relay?.disconnect() }
    func resumeRelay() { relay?.connect() }

    private func record(tool: String) {
        guard let text = ClaudeActivity.describe(tool) else { return }
        if let first = activity.first, first.text == text {
            activity[0].at = Date(); activity[0].count += 1
        } else {
            activity.insert(ClaudeActivity(text: text, at: Date()), at: 0)
            if activity.count > 20 { activity.removeLast(activity.count - 20) }
        }
    }

    func refreshAddresses() { addresses = NetworkAddresses.wifiIPv4() }
}

/// Одна строка в ленте «Activity» на экране Claude.
struct ClaudeActivity: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var at: Date
    var count = 1

    /// Инструмент MCP → понятная дизайнеру фраза. nil — не показываем (служебные чтения).
    static func describe(_ tool: String) -> String? {
        switch tool {
        case "create_project": "Created a project"
        case "create_version", "create_version_from_lottie", "apply_overrides": "Made a new version"
        case "restore_version": "Restored a version"
        case "render_frame": "Checked frames"
        case "get_feedback": "Read your comments"
        case "resolve_feedback": "Answered a comment"
        case "place_layer", "rename_layer", "replace_geometry", "place_asset": "Edited the scene"
        case "add_svg", "add_image", "add_assets": "Added files"
        case "export": "Exported JSON"
        case "show_in_app": "Showed you a moment"
        case "list_projects", "get_project", "list_versions", "get_version", "get_geometry", "list_assets", "diff_versions": "Looked at the project"
        default: nil
        }
    }
}
