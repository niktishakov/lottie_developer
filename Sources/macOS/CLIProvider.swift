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

/// Провайдер генерации сценария через локально залогиненный `claude` CLI (на подписке пользователя).
/// Тот же контракт можно скормить Codex (другой бинарь) — провайдер-агностично.
struct CLIProvider {
    var model: String = "opus"
    var maxRepairAttempts: Int = 2

    private struct Envelope: Decodable {
        let is_error: Bool?
        let result: String?
    }

    /// request → AnimationSpec. Repair-loop при невалидном JSON.
    func generateSpec(request: String, layerNames: [String], durationSeconds: Double) async throws -> (spec: AnimationSpec, raw: String) {
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
            let resultText = try await runClaude(claudePath: claudePath, system: system, user: user)
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

    // MARK: - claude invocation

    private func runClaude(claudePath: String, system: String, user: String) async throws -> String {
        let args = [
            "-p", user,
            "--append-system-prompt", system,
            "--output-format", "json",
            "--model", model,
            "--disallowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebSearch,WebFetch",
        ]
        // Прямой exec claude. КЛЮЧЕВОЕ: в PATH первой ставим папку node рядом с claude
        // (claude установлен под конкретную версию node — напр. v18.20.6/bin; shebang `env node`
        // должен взять ИМЕННО её, иначе nvm-дефолт другой версии ломает undici globalDispatcher).
        let nodeBinDir = (claudePath as NSString).deletingLastPathComponent
        let stdout = try await CLIProvider.runProcess(executable: claudePath, args: args, pathPrepend: nodeBinDir)

        guard let env = parseEnvelope(from: stdout) else {
            throw CLIProviderError.processFailed("Unexpected CLI output: \(stdout.suffix(300))")
        }
        if env.is_error == true {
            throw CLIProviderError.apiError(env.result ?? "unknown")
        }
        guard let result = env.result, !result.isEmpty else {
            throw CLIProviderError.emptyOutput
        }
        return result
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
        // Снять чужие credentials (иначе 401 Invalid bearer token); HOME оставляем (нужен для ~/.claude).
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
