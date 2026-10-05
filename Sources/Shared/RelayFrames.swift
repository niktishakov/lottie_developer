import Foundation

/// Кадры посредника (relay/src/protocol.ts): JSON-текст в WebSocket, тело base64 кусками по 1 МБ.
/// Первый кадр req/res, следующие req-body/res-body, у последнего more=false.
enum RelayFrames {
    static let chunk = 1024 * 1024
    static let maxBody = 100 * 1024 * 1024

    struct Request: Equatable {
        var id: String
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data
    }

    /// Ответ айфона → кадры.
    static func responseFrames(id: String, status: Int, headers: [String: String], body: Data) -> [String] {
        let parts = split(body)
        return parts.enumerated().map { i, part in
            var f: [String: Any] = ["id": id, "body": part.base64EncodedString(), "more": i < parts.count - 1]
            if i == 0 {
                f["t"] = "res"; f["status"] = status; f["headers"] = headers
            } else {
                f["t"] = "res-body"
            }
            let data = (try? JSONSerialization.data(withJSONObject: f, options: [.withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func split(_ body: Data) -> [Data] {
        guard body.count > chunk else { return [body] }
        return stride(from: 0, to: body.count, by: chunk).map { body.subdata(in: $0..<min($0 + chunk, body.count)) }
    }

    /// Собирает запросы из кадров req + req-body.
    struct Assembler {
        private var open: [String: Request] = [:]

        enum Result: Equatable { case none, request(Request), tooLarge(id: String) }

        mutating func add(_ text: String) -> Result {
            guard let f = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let t = f["t"] as? String, let id = f["id"] as? String else { return .none }
            let part = Data(base64Encoded: f["body"] as? String ?? "") ?? Data()
            switch t {
            case "req":
                open[id] = Request(id: id, method: f["method"] as? String ?? "GET", path: f["path"] as? String ?? "/",
                                   query: f["query"] as? String ?? "", headers: f["headers"] as? [String: String] ?? [:], body: part)
            case "req-body":
                guard open[id] != nil else { return .none }
                open[id]!.body.append(part)
            default:
                return .none
            }
            if (open[id]?.body.count ?? 0) > RelayFrames.maxBody { open[id] = nil; return .tooLarge(id: id) }
            if f["more"] as? Bool == true { return .none }
            return open.removeValue(forKey: id).map { .request($0) } ?? .none
        }
    }

    /// "a=1&b=x%20y" → ["a": "1", "b": "x y"]
    static func parseQuery(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let decode = { (s: String) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s }
            if let k = kv.first, !k.isEmpty { out[decode(k)] = kv.count > 1 ? decode(kv[1]) : "" }
        }
        return out
    }
}
