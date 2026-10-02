import Foundation

/// lottie-mcp — MCP-сервер (stdio, JSON-RPC 2.0, по сообщению на строку).
/// Даёт внешним ИИ-агентам полный доступ к проектам Lottie Developer: проекты, геометрия,
/// версии (история, дифф, откат), компиляция AnimationSpec → Lottie, экспорт, показ в приложении.
/// Хранилище общее с приложением (Application Support/LottieDeveloperMac), приложение подхватывает изменения на лету.

setvbuf(stdout, nil, _IOLBF, 0)

func writeMessage(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

func log(_ msg: String) {
    FileHandle.standardError.write("[lottie-mcp] \(msg)\n".data(using: .utf8)!)
}

MainActor.assumeIsolated {
    let server = MCPServer()
    log("started, storage: \(server.store.rootDir.path)")
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        guard let data = trimmed.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            writeMessage(["jsonrpc": "2.0", "id": NSNull(),
                          "error": ["code": -32700, "message": "Parse error"]])
            continue
        }
        if let response = server.handle(msg) {
            writeMessage(response)
        }
    }
}
