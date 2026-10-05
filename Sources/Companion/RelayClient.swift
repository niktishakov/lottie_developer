import Foundation
import Observation
import Security
import DeviceCheck
import CryptoKit

/// Подключение айфона к посреднику в интернете (relay/): Claude на любом ПК ходит на https-адрес,
/// посредник пересылает запросы сюда по WebSocket. Айфон сам подключается наружу — сеть, IP и брандмауэр не мешают.
@MainActor
@Observable
final class RelayClient {
    static let baseURL = URL(string: "https://lottie-relay.nikapps.workers.dev")!

    enum State: Equatable { case off, connecting, online, failed(String) }

    private(set) var state: State = .off
    private(set) var deviceID: String?

    /// Адрес айфона у посредника: https://…/d/<id>
    var base: String? { deviceID.map { "\(Self.baseURL.absoluteString)/d/\($0)" } }

    private let handler: HTTPHandler
    /// Текущий PIN: посредник по нему находит айфон для короткого входа …/pair.
    private let pin: @MainActor () -> String
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var assembler = RelayFrames.Assembler()
    private var wanted = false

    init(handler: @escaping HTTPHandler, pin: @escaping @MainActor () -> String) {
        self.handler = handler
        self.pin = pin
        deviceID = Keychain.read(Self.idKey)
    }

    func connect() {
        wanted = true
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func disconnect() {
        wanted = false
        loop?.cancel(); loop = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        state = .off
    }

    // MARK: - Цикл подключения

    private func run() async {
        var delay: Double = 1
        while wanted, !Task.isCancelled {
            state = .connecting
            do {
                let (id, secret) = try await credentials()
                deviceID = id
                try await session(id: id, secret: secret)
                delay = 1
            } catch RelayError.unknownDevice {
                // Посредник не знает айфон (например, данные посредника сброшены) — регистрируемся заново.
                Keychain.delete(Self.idKey); Keychain.delete(Self.secretKey)
                continue
            } catch {
                if Task.isCancelled || !wanted { break }
                state = .failed(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
        loop = nil
    }

    private func credentials() async throws -> (String, String) {
        if let id = Keychain.read(Self.idKey), let secret = Keychain.read(Self.secretKey) { return (id, secret) }
        var req = URLRequest(url: Self.baseURL.appending(path: "register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // С App Attest — основная квота посредника. Без него (симулятор, сбой у Apple) — маленькая, но регистрация пройдёт.
        let attested = try? await Self.attestationBody()
        req.httpBody = attested ?? Data("{}".utf8)
        var (data, resp) = try await URLSession.shared.data(for: req)
        // Аттест не принят (например, сбой проверки) — регистрируемся без него, чтобы приложение всё равно работало.
        if attested != nil, (resp as? HTTPURLResponse)?.statusCode != 200 {
            req.httpBody = Data("{}".utf8)
            (data, resp) = try await URLSession.shared.data(for: req)
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["deviceId"] as? String, let secret = obj["deviceSecret"] as? String
        else { throw RelayError.registration }
        Keychain.write(Self.idKey, id)
        Keychain.write(Self.secretKey, secret)
        return (id, secret)
    }

    /// {keyId, attestation, challenge}: ключ в Secure Enclave, Apple подписывает, что это наше приложение на настоящем айфоне.
    private static func attestationBody() async throws -> Data? {
        let service = DCAppAttestService.shared
        guard service.isSupported else { return nil }
        var ch = URLRequest(url: baseURL.appending(path: "attest/challenge"))
        ch.timeoutInterval = 10
        let (cd, cr) = try await URLSession.shared.data(for: ch)
        guard (cr as? HTTPURLResponse)?.statusCode == 200,
              let challenge = (try? JSONSerialization.jsonObject(with: cd) as? [String: Any])?["challenge"] as? String
        else { return nil }
        let keyId = try await service.generateKey()
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await service.attestKey(keyId, clientDataHash: hash)
        Keychain.write(attestKeyKey, keyId)
        return try JSONSerialization.data(withJSONObject: [
            "keyId": keyId, "attestation": attestation.base64EncodedString(), "challenge": challenge,
        ])
    }

    private func session(id: String, secret: String) async throws {
        var req = URLRequest(url: URL(string: "wss://\(Self.baseURL.host()!)/d/\(id)/connect")!)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        task = ws
        assembler = RelayFrames.Assembler()
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil); if task === ws { task = nil } }

        // Ping раз в 20 с: Cloudflare отвечает "pong" сам, соединение не засыпает.
        // PIN отправляем только при подключении и когда он поменялся: каждый такой кадр — платный запрос.
        let pinger = Task { [pin] in
            var sentPIN: String?
            var tick = 0
            while !Task.isCancelled {
                let current = pin()
                if current != sentPIN, let frame = Self.pinFrame(current) {
                    if (try? await ws.send(.string(frame))) != nil { sentPIN = current }
                }
                if tick % 20 == 0 { try? await ws.send(.string("ping")) }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { pinger.cancel() }

        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch {
                if (ws.response as? HTTPURLResponse)?.statusCode == 401 { throw RelayError.unknownDevice }
                throw error
            }
            state = .online
            guard case .string(let text) = message, text != "pong" else { continue }
            switch assembler.add(text) {
            case .none: break
            case .tooLarge(let rid):
                send(ws, RelayFrames.responseFrames(id: rid, status: 413, headers: [:], body: Data("Body is larger than 100 MB".utf8)))
            case .request(let r):
                Task { await self.answer(r, on: ws) }
            }
        }
    }

    private func answer(_ r: RelayFrames.Request, on ws: URLSessionWebSocketTask) async {
        var headers = r.headers
        // По этому адресу страница сопряжения собирает команду для Claude.
        if let base { headers["x-relay-base"] = base }
        // remoteIP "relay" — запрос никогда не считается локальным, токен проверяется всегда.
        let req = HTTPRequest(method: r.method, path: r.path, query: RelayFrames.parseQuery(r.query),
                              headers: headers, body: r.body, remoteIP: "relay")
        let res = await handler(req)
        send(ws, RelayFrames.responseFrames(id: r.id, status: res.status, headers: res.headers, body: res.body))
    }

    private static func pinFrame(_ pin: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: ["t": "pin", "pin": pin]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    private func send(_ ws: URLSessionWebSocketTask, _ frames: [String]) {
        Task {
            for f in frames { try? await ws.send(.string(f)) }
        }
    }

    enum RelayError: LocalizedError {
        case registration, unknownDevice
        var errorDescription: String? {
            switch self {
            case .registration: return "Could not register with the relay. Check the internet connection."
            case .unknownDevice: return "The relay does not know this iPhone."
            }
        }
    }

    private static let idKey = "relay.deviceId"
    private static let secretKey = "relay.deviceSecret"
    private static let attestKeyKey = "relay.attestKeyId"
}

/// Строки в Keychain (только этот айфон, после первой разблокировки).
enum Keychain {
    private static let service = "com.nikapps.lottie.developer.relay"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
