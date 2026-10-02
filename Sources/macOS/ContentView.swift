#if os(macOS)
import SwiftUI
import AppKit

/// Роутер: Home (список проектов) ↔ Editor (проект).
struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var openProjectID: UUID?
    @State private var command: ProjectStore.UICommand?
    @State private var lastCommandAt: Date?

    var body: some View {
        Group {
            if let id = openProjectID, store.project(id) != nil {
                EditorView(store: store, projectID: id, command: command,
                           onClose: { openProjectID = nil })
                    .id(id)
            } else {
                HomeView(store: store, onOpen: { openProjectID = $0 })
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .task { await syncWithMCP() }
    }

    /// Live-sync с lottie-mcp: перечитываем проекты с диска и выполняем UI-команды (show_in_app).
    private func syncWithMCP() async {
        store.exportSampleForCLI()
        lastCommandAt = store.readUICommand()?.issuedAt
        while !Task.isCancelled {
            if openProjectID == nil, store.readAppState()?.projectID != nil {
                store.writeAppState(.init(frame: 0, playing: false, mode: "", engine: "", activeEngine: "",
                                          overrides: [:], updatedAt: Date()))
            }
            store.reloadIfChanged()
            if let cmd = store.readUICommand(), cmd.issuedAt != lastCommandAt {
                lastCommandAt = cmd.issuedAt
                if let pid = cmd.projectID, store.project(pid) != nil {
                    openProjectID = pid
                    command = cmd
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}
#endif
