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
                if kind == .mcp { self?.lastMCPAt = Date() } else { self?.lastViewerAt = Date() }
            }
        }
        self.routes = routes
        let server = HTTPServer(port: Self.port) { req in await routes.handle(req) }
        do { try server.start(); http = server; isRunning = true; error = nil }
        catch { self.error = error.localizedDescription; isRunning = false }
        let relay = self.relay ?? RelayClient { req in await routes.handle(req) }
        self.relay = relay
        relay.connect()
    }

    func stop() { http?.stop(); http = nil; relay?.disconnect(); relay = nil; isRunning = false }

    /// Приложение свёрнуто — iOS всё равно заморозит соединение; открыто — подключаемся снова.
    func pauseRelay() { relay?.disconnect() }
    func resumeRelay() { relay?.connect() }

    func refreshAddresses() { addresses = NetworkAddresses.wifiIPv4() }
}
