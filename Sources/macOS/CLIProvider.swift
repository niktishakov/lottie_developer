#if os(macOS)
import Foundation

enum CLIProviderError: LocalizedError {
    case claudeNotFound
    case processFailed(String)
    case emptyOutput
    case apiError(String)
    case invalidSpec(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "`claude` CLI not found. Install Claude Code and run `claude` once to log in."
        case .processFailed(let m): return "claude process failed: \(m)"
        case .emptyOutput: return "claude returned empty output"
        case .apiError(let m): return "claude error: \(m)"
        case .invalidSpec(let m): return "AI output was not a valid AnimationSpec: \(m)"
        }
    }
}

struct TokenUsage: Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var costUSD: Double = 0
    var rateLimitStatus: String = ""
    var rateLimitResetsAt: Date?

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Провайдер генерации сценария через локально залогиненный `claude` CLI (на подписке пользователя).
/// Тот же контракт можно скормить Codex (другой бинарь) — провайдер-агностично.
struct CLIProvider {
    var model: String = "opus"
    var effort: String = ""   // "" → флаг --effort не передаём (дефолт CLI)
    var fast: Bool = false
    var maxRepairAttempts: Int = 2

    private struct Envelope: Decodable {
        let is_error: Bool?
        let result: String?
    }

    /// request → AnimationSpec. Repair-loop при невалидном JSON.
    func generateSpec(request: String, layerNames: [String], durationSeconds: Double,
                      onTokenUpdate: (@Sendable (TokenUsage) -> Void)? = nil) async throws -> (spec: AnimationSpec, raw: String) {
        let claudePath = try CLIProvider.resolveClaudePath()
        let system = CLIPrompts.systemPrompt(layerNames: layerNames)

        var repairNote = ""
        var lastError = "unknown"
        var attempt = 0
        while attempt <= maxRepairAttempts {
            let user = CLIPrompts.userPrompt(
                request: request, layerNames: layerNames,
                durationSeconds: durationSeconds, repairNote: repairNote
            )
            let resultText = try await runClaudeStreaming(claudePath: claudePath, system: system, user: user, onTokenUpdate: onTokenUpdate)
            do {
                let spec = try CLIPrompts.decodeSpec(from: resultText)
                return (spec, resultText)
            } catch {
                lastError = error.localizedDescription
                repairNote = "Your previous reply did not parse as AnimationSpec JSON (\(lastError)). "
                    + "Reply with ONLY the JSON object — no prose, no markdown, no code fences."
                attempt += 1
            }
        }
        throw CLIProviderError.invalidSpec(lastError)
    }

    // MARK: - claude invocation (streaming)

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ld_stream.log")
    private static func debugLog(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fh = try? FileHandle(forWritingTo: logURL) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private final class StreamState: @unchecked Sendable {
        var resultText: String?
        var isError = false
        var buffer = Data()
        var accumulated = TokenUsage()
        var retryCount = 0
        weak var process: Process?
    }

    private func runClaudeStreaming(claudePath: String, system: String, user: String,
                                    onTokenUpdate: (@Sendable (TokenUsage) -> Void)?) async throws -> String {
        var args = [
            "-p", user,
            "--append-system-prompt", system,
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--disallowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch",
            "--max-turns", "1",
        ]
        if !effort.isEmpty { args += ["--effort", effort] }
        let nodeBinDir = (claudePath as NSString).deletingLastPathComponent

        let state = StreamState()

        return try await withCheckedThrowingContinuation { continuation in
            let onUpdate = onTokenUpdate
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: claudePath)
                    proc.arguments = args
                    proc.environment = CLIProvider.cleanEnvironment(pathPrepend: nodeBinDir)

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe

                    CLIProvider.debugLog("setting up readabilityHandler for pipe")
                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        CLIProvider.debugLog("readabilityHandler: chunk=\(chunk.count) bytes")
                        guard !chunk.isEmpty else { return }
                        state.buffer.append(chunk)

                        while let newlineRange = state.buffer.range(of: Data("\n".utf8)) {
                            let lineData = state.buffer.subdata(in: state.buffer.startIndex..<newlineRange.lowerBound)
                            state.buffer.removeSubrange(state.buffer.startIndex...newlineRange.lowerBound)

                            guard let line = String(data: lineData, encoding: .utf8),
                                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                            CLIProvider.parseStreamLine(line, state: state, onTokenUpdate: onUpdate)
                        }
                    }

                    state.process = proc
                    try proc.run()
                    CLIProvider.debugLog("proc launched pid=\(proc.processIdentifier)")
                    proc.waitUntilExit()
                    CLIProvider.debugLog("proc exited status=\(proc.terminationStatus)")

                    outPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        state.buffer.append(remaining)
                    }
                    while let newlineRange = state.buffer.range(of: Data("\n".utf8)) {
                        let lineData = state.buffer.subdata(in: state.buffer.startIndex..<newlineRange.lowerBound)
                        state.buffer.removeSubrange(state.buffer.startIndex...newlineRange.lowerBound)
                        guard let line = String(data: lineData, encoding: .utf8),
                              !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        CLIProvider.parseStreamLine(line, state: state, onTokenUpdate: onUpdate)
                    }
                    if !state.buffer.isEmpty, let tail = String(data: state.buffer, encoding: .utf8),
                       !tail.trimmingCharacters(in: .whitespaces).isEmpty {
                        CLIProvider.parseStreamLine(tail, state: state, onTokenUpdate: onUpdate)
                    }

                    if state.isError {
                        continuation.resume(throwing: CLIProviderError.apiError(state.resultText ?? "unknown"))
                    } else if let result = state.resultText, !result.isEmpty {
                        continuation.resume(returning: result)
                    } else if proc.terminationStatus != 0 {
                        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: CLIProviderError.processFailed("exit \(proc.terminationStatus): \(err.prefix(300))"))
                    } else {
                        continuation.resume(throwing: CLIProviderError.emptyOutput)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func parseStreamLine(_ line: String, state: StreamState,
                                         onTokenUpdate: (@Sendable (TokenUsage) -> Void)?) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog("unparseable: \(line.prefix(120))")
            return
        }

        let type = obj["type"] as? String
        let subtype = obj["subtype"] as? String
        debugLog("event type=\(type ?? "nil") subtype=\(subtype ?? "-") keys=\(Array(obj.keys).joined(separator: ","))")

        if type == "result" {
            state.resultText = obj["result"] as? String
            state.isError = obj["is_error"] as? Bool ?? false
            if let usage = obj["usage"] as? [String: Any] {
                state.accumulated.inputTokens = usage["input_tokens"] as? Int ?? state.accumulated.inputTokens
                state.accumulated.outputTokens = usage["output_tokens"] as? Int ?? state.accumulated.outputTokens
                state.accumulated.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? state.accumulated.cacheReadTokens
                state.accumulated.cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? state.accumulated.cacheCreationTokens
            }
            state.accumulated.costUSD = (obj["total_cost_usd"] as? Double) ?? state.accumulated.costUSD
            debugLog("RESULT: in=\(state.accumulated.inputTokens) out=\(state.accumulated.outputTokens) cost=\(state.accumulated.costUSD)")
            onTokenUpdate?(state.accumulated)
        } else if type == "assistant", let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] {
            state.accumulated.inputTokens = usage["input_tokens"] as? Int ?? 0
            state.accumulated.outputTokens = usage["output_tokens"] as? Int ?? 0
            state.accumulated.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
            state.accumulated.cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
            debugLog("ASSISTANT: in=\(state.accumulated.inputTokens) out=\(state.accumulated.outputTokens)")
            onTokenUpdate?(state.accumulated)
        } else if type == "system", subtype == "api_retry" {
            let errorStatus = obj["error_status"] as? Int ?? 0
            let attempt = obj["attempt"] as? Int ?? 0
            let errorMsg = obj["error"] as? String ?? "unknown"
            debugLog("API RETRY: status=\(errorStatus) attempt=\(attempt) error=\(errorMsg)")
            state.retryCount = attempt
            var tu = state.accumulated
            tu.rateLimitStatus = "retrying \(attempt)/5 (\(errorStatus))"
            state.accumulated = tu
            onTokenUpdate?(state.accumulated)
            if attempt >= 5 {
                debugLog("MAX RETRIES reached — killing process")
                state.isError = true
                state.resultText = "Rate limited (HTTP \(errorStatus)). Try a different model or wait a few minutes."
                state.process?.terminate()
            }
        } else if type == "rate_limit_event", let info = obj["rate_limit_info"] as? [String: Any] {
            state.accumulated.rateLimitStatus = info["status"] as? String ?? ""
            if let resetsEpoch = info["resetsAt"] as? TimeInterval {
                state.accumulated.rateLimitResetsAt = Date(timeIntervalSince1970: resetsEpoch)
            }
            onTokenUpdate?(state.accumulated)
        }
    }

    /// stdout может содержать строки от .zshrc/nvm — ищем JSON-строку результата claude.
    private func parseEnvelope(from stdout: String) -> Envelope? {
        let decoder = JSONDecoder()
        // 1) весь вывод целиком
        if let data = stdout.data(using: .utf8), let env = try? decoder.decode(Envelope.self, from: data),
           env.result != nil || env.is_error != nil {
            return env
        }
        // 2) построчно с конца — claude печатает однострочный JSON
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.contains("\"result\"") || trimmed.contains("\"is_error\"") else { continue }
            if let data = trimmed.data(using: .utf8), let env = try? decoder.decode(Envelope.self, from: data) {
                return env
            }
        }
        return nil
    }

    // MARK: - process plumbing

    /// Резолвит абсолютный путь к `claude`: GUI-приложение из Finder не наследует shell-PATH (nvm),
    /// поэтому спрашиваем login-shell, затем пробуем типовые места.
    static func resolveClaudePath() throws -> String {
        if let viaShell = try? runProcessSync(executable: "/bin/zsh", args: ["-lc", "command -v claude"])
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !viaShell.isEmpty,
           FileManager.default.isExecutableFile(atPath: viaShell) {
            return viaShell
        }
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw CLIProviderError.claudeNotFound
    }

    static func cleanEnvironment(pathPrepend: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") {
            env.removeValue(forKey: key)
        }
        let base = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        var path = base + (env["PATH"].map { ":" + $0 } ?? "")
        if let pathPrepend, !pathPrepend.isEmpty {
            path = pathPrepend + ":" + path
        }
        env["PATH"] = path
        return env
    }

    static func runProcess(executable: String, args: [String], pathPrepend: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = try runProcessSync(executable: executable, args: args, pathPrepend: pathPrepend)
                    continuation.resume(returning: out)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    static func runProcessSync(executable: String, args: [String], pathPrepend: String? = nil) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = cleanEnvironment(pathPrepend: pathPrepend)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        // Читаем до завершения (вывод claude небольшой — envelope + spec).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        if out.isEmpty, proc.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw CLIProviderError.processFailed("exit \(proc.terminationStatus): \(err.prefix(300))")
        }
        return out
    }

    /// Запуск `claude <args>` с захватом stdout/stderr/кода возврата — для auth-команд,
    /// где важно показать вывод и не падать на ненулевом коде. PATH с node рядом с claude.
    static func runResult(args: [String]) async throws -> (out: String, err: String, code: Int32) {
        let claudePath = try resolveClaudePath()
        let nodeBinDir = (claudePath as NSString).deletingLastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: claudePath)
                proc.arguments = args
                proc.environment = cleanEnvironment(pathPrepend: nodeBinDir)
                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: (
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? "",
                        proc.terminationStatus
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
