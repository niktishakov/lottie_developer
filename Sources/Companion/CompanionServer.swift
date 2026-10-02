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

    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var addresses: [String] = []
    /// Когда последний раз обращался Claude (MCP) / браузер.
    private(set) var lastMCPAt: Date?
    private(set) var lastViewerAt: Date?

    var pin: String { auth.pin }
    var token: String { auth.token }

    /// Команда, которую дизайнер вставляет в Claude Code на Windows.
    var mcpCommand: String {
        let host = addresses.first ?? "<iphone-ip>"
        return "claude mcp add -s user --transport http lottie-developer http://\(host):\(Self.port)/mcp --header \"Authorization: Bearer \(token)\""
    }
    var viewerURL: String { "http://\(addresses.first ?? "<iphone-ip>"):\(Self.port)" }

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
    }

    func stop() { http?.stop(); http = nil; isRunning = false }

    func refreshAddresses() { addresses = NetworkAddresses.wifiIPv4() }
}
