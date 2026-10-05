#if os(iOS)
import SwiftUI
import UIKit

/// Корень iPhone-версии Lottie Developer: проекты + подключение Claude. Владеет сервером.
struct DeveloperRootView: View {
    enum Tab: Hashable { case projects, claude }

    @State private var server = CompanionServer()
    @State private var tab: Tab = .claude
    @State private var path: [UUID] = []
    @State private var command: ProjectStore.UICommand?
    @State private var lastCommandAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                ProjectsListView(store: server.store, claudeOnline: server.relay?.state == .online)
                    .navigationDestination(for: UUID.self) { id in
                        ProjectPlayerView(store: server.store, projectID: id,
                                          command: command?.projectID == id ? command : nil)
                    }
            }
            .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
            .tag(Tab.projects)

            NavigationStack {
                ClaudeConnectView(server: server)
            }
            .tabItem { Label("Claude", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(Tab.claude)
        }
        .task {
            server.start()
            if server.store.projects.isEmpty == false { tab = .projects }
            await syncLoop()
        }
        .onChange(of: server.isRunning, initial: true) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: server.resumeRelay()
            case .background: server.pauseRelay()
            default: break
            }
        }
    }

    /// Live-sync с MCP: перечитываем проекты и выполняем UI-команды (show_in_app), как ContentView на macOS.
    private func syncLoop() async {
        lastCommandAt = server.store.readUICommand()?.issuedAt
        while !Task.isCancelled {
            server.store.reloadIfChanged()
            if let cmd = server.store.readUICommand(), cmd.issuedAt != lastCommandAt {
                lastCommandAt = cmd.issuedAt
                if let pid = cmd.projectID, server.store.project(pid) != nil {
                    command = cmd
                    let switching = tab != .projects
                    tab = .projects
                    // Переход внутрь вкладки во время её переключения теряется — ждём кадр.
                    if switching { try? await Task.sleep(for: .milliseconds(350)) }
                    if path.last != pid { path = [pid] }
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}
#endif
