import Foundation
import Network

/// Небольшой HTTP/1.1 сервер на Network.framework.
/// Keep-alive, Content-Length и chunked тела, Expect: 100-continue, CORS, таймаут простоя.
final class HTTPServer: @unchecked Sendable {
    static let maxBodySize = 200 * 1024 * 1024
    static let maxHeaderSize = 64 * 1024
    static let idleTimeout: TimeInterval = 60

    private let port: UInt16
    private let handler: HTTPHandler
    private let queue = DispatchQueue(label: "lottiedev.http.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(port: UInt16, handler: @escaping HTTPHandler) {
        self.port = port
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    func start() throws {
        stop()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad port \(port)"])
        }
        let listener = try NWListener(using: params, on: nwPort)
        // name: nil — система подставит имя устройства.
        listener.service = NWListener.Service(name: nil, type: "_lottiedev._tcp")
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                NSLog("HTTPServer listener failed: \(err)")
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        let work = {
            self.listener?.cancel()
            self.listener = nil
            for c in self.connections.values { c.close() }
            self.connections.removeAll()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private func accept(_ nw: NWConnection) {
        // Вызывается на queue.
        let conn = HTTPConnection(connection: nw, queue: queue, handler: handler)
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.onClose = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        conn.start()
    }
}

// MARK: - Connection

private final class HTTPConnection: @unchecked Sendable {
    private enum BodyMode { case none, length(Int), chunked }
    private enum ChunkState { case size, data(Int), dataCRLF, trailer }

    private struct Head {
        var method: String
        var target: String
        var version: String
        var headers: [String: String]
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPHandler
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var head: Head?
    private var bodyMode: BodyMode = .none
    private var body = Data()
    private var chunkState: ChunkState = .size
    private var busy = false        // запрос в обработке, не читаем дальше
    private var receiving = false
    private var closed = false
    private var idleTimer: DispatchWorkItem?
    private let remoteIP: String

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPHandler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.remoteIP = Self.ip(from: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        idleTimer = nil
        connection.cancel()
        let cb = onClose
        onClose = nil
        cb?()
    }

    // MARK: Idle

    private func armIdleTimer() {
        idleTimer?.cancel()
        guard !closed else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.close()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + HTTPServer.idleTimeout, execute: item)
    }

    // MARK: Receive

    private func receive() {
        guard !closed, !receiving, !busy else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiving = false
            if let data, !data.isEmpty {
                self.armIdleTimer()
                self.buffer.append(data)
                self.process()
            }
            if self.closed { return }
            if error != nil || isComplete {
                // Клиент закрыл запись. Если запрос в работе — дождёмся ответа.
                if !self.busy { self.close() } else { self.peerDone = true }
                return
            }
            self.receive()
        }
    }

    private var peerDone = false

    // MARK: Parse

    private func process() {
        while !closed && !busy {
            if head == nil {
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > HTTPServer.maxHeaderSize { fail(431) }
                    return
                }
                let headData = buffer[buffer.startIndex..<range.lowerBound]
                buffer = Data(buffer[range.upperBound...])
                guard let parsed = parseHead(headData) else { fail(400); return }
                head = parsed
                body = Data()
                chunkState = .size

                let te = parsed.headers["transfer-encoding"]?.lowercased() ?? ""
                if te.contains("chunked") {
                    bodyMode = .chunked
                } else if let cl = parsed.headers["content-length"] {
                    guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0 else { fail(400); return }
                    guard n <= HTTPServer.maxBodySize else { fail(413); return }
                    bodyMode = n > 0 ? .length(n) : .none
                    if n > 0 { body.reserveCapacity(n) }
                } else if !te.isEmpty {
                    fail(400); return
                } else {
                    bodyMode = .none
                }

                if case .none = bodyMode {} else if
                    parsed.headers["expect"]?.lowercased() == "100-continue", buffer.isEmpty {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }

            switch bodyMode {
            case .none:
                dispatch()
            case .length(let n):
                let need = n - body.count
                if buffer.count <= need {
                    body.append(buffer)
                    buffer.removeAll(keepingCapacity: false)
                } else {
                    body.append(buffer[buffer.startIndex..<buffer.startIndex + need])
                    buffer = Data(buffer[(buffer.startIndex + need)...])
                }
                if body.count == n { dispatch() } else { return }
            case .chunked:
                guard let done = parseChunks() else { fail(400); return }
                if done { dispatch() } else { return }
            }
        }
    }

    /// true — тело готово, false — нужно больше данных, nil — ошибка.
    private func parseChunks() -> Bool? {
        var pos = buffer.startIndex
        defer { if pos > buffer.startIndex { buffer = Data(buffer[pos...]) } }
        let crlf = Data("\r\n".utf8)
        while true {
            switch chunkState {
            case .size:
                guard let r = buffer.range(of: crlf, in: pos..<buffer.endIndex) else {
                    return buffer.endIndex - pos > 1024 ? nil : false
                }
                guard let line = String(data: buffer[pos..<r.lowerBound], encoding: .ascii) else { return nil }
                let hex = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !hex.isEmpty, let size = Int(hex, radix: 16), size >= 0 else { return nil }
                pos = r.upperBound
                if size == 0 {
                    chunkState = .trailer
                } else {
                    guard body.count + size <= HTTPServer.maxBodySize else { return nil }
                    chunkState = .data(size)
                }
            case .data(let remaining):
                let avail = buffer.endIndex - pos
                if avail == 0 { return false }
                let take = min(avail, remaining)
                body.append(buffer[pos..<pos + take])
                pos += take
                chunkState = take == remaining ? .dataCRLF : .data(remaining - take)
            case .dataCRLF:
                if buffer.endIndex - pos < 2 { return false }
                guard buffer[pos] == 13, buffer[pos + 1] == 10 else { return nil }
                pos += 2
                chunkState = .size
            case .trailer:
                // Трейлеры игнорируем: строки до пустой.
                guard let r = buffer.range(of: crlf, in: pos..<buffer.endIndex) else {
                    return buffer.endIndex - pos > HTTPServer.maxHeaderSize ? nil : false
                }
                let empty = r.lowerBound == pos
                pos = r.upperBound
                if empty { return true }
            }
        }
    }

    private func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        // Допускаем пустые строки перед запросом (RFC 9112 §2.2).
        while let f = lines.first, f.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let version = String(parts[2]).uppercased()
        guard version == "HTTP/1.1" || version == "HTTP/1.0",
              method.allSatisfy({ $0.isLetter }), !method.isEmpty,
              target.hasPrefix("/") || target == "*" || target.hasPrefix("http") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let old = headers[key] { headers[key] = old + ", " + value } else { headers[key] = value }
        }
        return Head(method: method, target: target, version: version, headers: headers)
    }

    // MARK: Dispatch

    private func dispatch() {
        guard let head else { return }
        self.head = nil
        let reqBody = body
        body = Data()
        bodyMode = .none
        busy = true
        idleTimer?.cancel()

        let connHeader = head.headers["connection"]?.lowercased() ?? ""
        let keepAlive = head.version == "HTTP/1.1" ? !connHeader.contains("close") : connHeader.contains("keep-alive")

        var target = head.target
        if target.hasPrefix("http"), let u = URL(string: target) {
            target = u.path.isEmpty ? "/" : u.path
            if let q = u.query { target += "?" + q }
        }
        let pathPart: Substring
        let queryPart: Substring
        if let q = target.firstIndex(of: "?") {
            pathPart = target[..<q]
            queryPart = target[target.index(after: q)...]
        } else {
            pathPart = Substring(target)
            queryPart = ""
        }
        let path = String(pathPart).removingPercentEncoding ?? String(pathPart)
        let query = Self.parseQuery(queryPart)

        if head.method == "OPTIONS" {
            let resp = HTTPResponse(status: 204, headers: [
                "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Max-Age": "86400",
            ], body: Data())
            send(resp, keepAlive: keepAlive, isHead: false)
            return
        }

        let request = HTTPRequest(method: head.method, path: path, query: query,
                                  headers: head.headers, body: reqBody, remoteIP: remoteIP)
        let handler = self.handler
        let isHead = head.method == "HEAD"
        Task { [weak self] in
            let resp = await handler(request)
            guard let self else { return }
            self.queue.async { self.send(resp, keepAlive: keepAlive, isHead: isHead) }
        }
    }

    private func send(_ resp: HTTPResponse, keepAlive: Bool, isHead: Bool) {
        guard !closed else { return }
        let keep = keepAlive && !peerDone
        var out = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        var seen = Set<String>()
        for (k, v) in resp.headers {
            let lk = k.lowercased()
            if lk == "content-length" || lk == "connection" || lk == "transfer-encoding" { continue }
            seen.insert(lk)
            out += "\(k): \(v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n"
        }
        if !seen.contains("access-control-allow-origin") { out += "Access-Control-Allow-Origin: *\r\n" }
        out += "Content-Length: \(resp.body.count)\r\n"
        out += keep ? "Connection: keep-alive\r\nKeep-Alive: timeout=\(Int(HTTPServer.idleTimeout))\r\n" : "Connection: close\r\n"
        out += "\r\n"
        var data = Data(out.utf8)
        if !isHead { data.append(resp.body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil || !keep { self.close(); return }
                self.busy = false
                self.armIdleTimer()
                self.process()   // пайплайнинг: в буфере может быть следующий запрос
                self.receive()
            }
        })
    }

    private func fail(_ status: Int) {
        guard !closed else { return }
        busy = true
        idleTimer?.cancel()
        let body = Data("\(status) \(Self.reason(status))\n".utf8)
        var out = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        out += "Content-Type: text/plain; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\n"
        out += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(out.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.close() }
        })
    }

    // MARK: Helpers

    static func parseQuery(_ s: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for pair in s.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = decode(kv[0])
            let v = kv.count > 1 ? decode(kv[1]) : ""
            if !k.isEmpty { result[k] = v }
        }
        return result
    }

    private static func decode(_ s: Substring) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    static func ip(from endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: s = "\(host)"
        }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.lowercased().hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default:
            switch code {
            case 200..<300: return "OK"
            case 300..<400: return "Redirect"
            case 400..<500: return "Client Error"
            default: return "Server Error"
            }
        }
    }
}

// MARK: - Addresses

enum NetworkAddresses {
    /// IPv4 адреса: сначала en0 (Wi‑Fi), затем остальные поднятые не-loopback интерфейсы.
    static func wifiIPv4() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var en0: [String] = []
        var others: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if ip.hasPrefix("169.254.") { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name == "en0" { if !en0.contains(ip) { en0.append(ip) } }
            else if !others.contains(ip) && !en0.contains(ip) { others.append(ip) }
        }
        return en0 + others.filter { !en0.contains($0) }
    }
}
