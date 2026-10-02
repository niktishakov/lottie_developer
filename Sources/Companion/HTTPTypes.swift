import Foundation

/// Общие типы HTTP для сервера на iPhone (MCP по сети + просмотрщик для браузера ПК).
struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Ключи в нижнем регистре.
    var headers: [String: String]
    var body: Data
    var remoteIP: String
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
    static func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: Data(s.utf8))
    }
    static func data(_ d: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: d)
    }
}

typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse
