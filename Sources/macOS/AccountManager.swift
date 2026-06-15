#if os(macOS)
import Foundation
import AppKit
import Observation

/// Управление аккаунтом Claude, на котором работает генерация.
/// Источник истины — локальный `claude` CLI (OAuth-подписка). Команды:
///   `claude auth status`  — текущий аккаунт (JSON),
///   `claude auth logout`  — выход,
///   `claude auth login`   — вход (интерактивный + браузер) → запускаем в Terminal.app.
@MainActor
@Observable
final class AccountManager {

    /// Разобранный `claude auth status`.
    struct AuthStatus: Decodable {
        var loggedIn: Bool
        var authMethod: String?
        var apiProvider: String?
        var email: String?
        var orgName: String?
        var subscriptionType: String?
        var billingType: String?

        var isFirstParty: Bool { (apiProvider ?? "").lowercased() == "firstparty" }
    }

    private(set) var status: AuthStatus?
    private(set) var statusError: String?
    private(set) var busy = false
    private(set) var message: String = ""

    /// Запрашивает `claude auth status` и парсит JSON.
    func refresh() async {
        busy = true; message = ""; statusError = nil
        defer { busy = false }
        do {
            let r = try await CLIProvider.runResult(args: ["auth", "status"])
            let text = (r.out.isEmpty ? r.err : r.out)
            guard let json = Self.extractJSONObject(from: text),
                  let data = json.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(AuthStatus.self, from: data) else {
                status = nil
                statusError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Could not read auth status (exit \(r.code))"
                    : text.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            // `auth status` в очищенном окружении часто отдаёт только loggedIn/apiProvider.
            // Профиль (email/организация/план) дочитываем из ~/.claude.json (oauthAccount) —
            // это метаданные аккаунта, не токены.
            var merged = parsed
            if merged.loggedIn {
                let local = Self.loadLocalAccount()
                if merged.email == nil { merged.email = local.email }
                if merged.orgName == nil { merged.orgName = local.org }
                if merged.subscriptionType == nil { merged.subscriptionType = local.plan }
                if merged.billingType == nil { merged.billingType = local.billing }
            }
            status = merged
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }

    /// Читает профиль аккаунта из ~/.claude.json (или $CLAUDE_CONFIG_DIR/.claude.json).
    private static func loadLocalAccount() -> (email: String?, org: String?, plan: String?, billing: String?) {
        let fm = FileManager.default
        var path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            let alt = (dir as NSString).appendingPathComponent(".claude.json")
            if fm.fileExists(atPath: alt) { path = alt }
        }
        guard let data = fm.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oa = root["oauthAccount"] as? [String: Any] else { return (nil, nil, nil, nil) }
        let plan = (oa["subscriptionType"] as? String).map { $0.capitalized }
            ?? prettyBilling(oa["billingType"] as? String)
        let billing = prettyBilling(oa["billingType"] as? String)
        return (oa["emailAddress"] as? String, oa["organizationName"] as? String, plan, billing)
    }

    private static func prettyBilling(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "stripe_subscription": return "Subscription"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `claude auth logout` — выход из текущего аккаунта.
    func logout() async {
        busy = true; message = ""
        defer { busy = false }
        do {
            let r = try await CLIProvider.runResult(args: ["auth", "logout"])
            let out = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            message = r.code == 0 ? "Logged out." : "Logout: \(out.isEmpty ? "exit \(r.code)" : out)"
        } catch {
            message = "Logout failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// `claude auth login` интерактивен (терминал + браузер). Запускаем через временный `.command`
    /// файл, открываемый в Terminal — без необходимости в Apple Events (automation) разрешении.
    /// После завершения пользователь возвращается в приложение и жмёт Refresh.
    func openLoginInTerminal() {
        guard let claudePath = try? CLIProvider.resolveClaudePath() else {
            message = "`claude` CLI not found. Install Claude Code first."
            return
        }
        let nodeBinDir = (claudePath as NSString).deletingLastPathComponent
        let script = """
        #!/bin/zsh
        unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
        echo "Signing in to Claude (subscription)…"
        echo
        PATH="\(nodeBinDir):$PATH" "\(claudePath)" auth login --claudeai
        echo
        echo "Done. Close this window and tap Refresh in Lottie Developer."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lottie-claude-login.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            message = "Complete sign-in in the Terminal window, then tap Refresh."
        } catch {
            message = "Could not start sign-in: \(error.localizedDescription)"
        }
    }

    // MARK: - helpers

    /// Достаёт первый сбалансированный JSON-объект из текста (вывод может включать строки nvm/.zshrc).
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { return String(text[start...idx]) } }
            idx = text.index(after: idx)
        }
        return nil
    }
}
#endif
