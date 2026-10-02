#if os(macOS)
import Foundation
import AppKit

/// Рабочая папка дизайнера для Claude: `.mcp.json` (MCP внутри этого приложения), `CLAUDE.md`, скилл `/animate`.
/// Дизайнер открывает её в Claude — и у Claude сразу есть инструменты и порядок работы. Xcode не нужен.
enum WorkspaceSetup {

    private static let key = "workspace.path"

    /// lottie-mcp лежит рядом с исполняемым файлом приложения.
    static var mcpURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/lottie-mcp")
    }

    static var isMCPBundled: Bool { FileManager.default.isExecutableFile(atPath: mcpURL.path) }

    static var savedURL: URL? {
        UserDefaults.standard.string(forKey: key).map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Lottie Workspace")
    }

    static func install(at dir: URL) throws {
        let fm = FileManager.default
        let skills = dir.appendingPathComponent(".claude/skills/animate", isDirectory: true)
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)

        if let claude = Bundle.main.url(forResource: "CLAUDE", withExtension: "md", subdirectory: "Workspace") {
            try replace(dir.appendingPathComponent("CLAUDE.md"), with: try Data(contentsOf: claude))
        }
        if let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") {
            try replace(skills.appendingPathComponent("SKILL.md"), with: try Data(contentsOf: skill))
        }
        let mcp: [String: Any] = ["mcpServers": ["lottie-developer": ["command": mcpURL.path, "args": []]]]
        try replace(dir.appendingPathComponent(".mcp.json"),
                    with: try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        UserDefaults.standard.set(dir.path, forKey: key)
    }

    /// При запуске: обновить файлы в уже созданной папке (новая версия приложения, другой путь к .app).
    static func refreshIfInstalled() {
        guard let dir = savedURL else { return }
        try? install(at: dir)
    }

    /// Скачанный DMG помечен карантином. Приложение дизайнер уже разрешил запускать, а вложенный lottie-mcp
    /// запускает Claude — снимаем флаг с собственного бандла, чтобы Gatekeeper его не блокировал.
    static func stripQuarantine() {
        let path = Bundle.main.bundlePath
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = ["-dr", "com.apple.quarantine", path]
            try? p.run(); p.waitUntilExit()
        }
    }

    private static func replace(_ url: URL, with data: Data) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
#endif
