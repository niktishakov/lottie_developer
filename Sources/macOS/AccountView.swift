#if os(macOS)
import SwiftUI

/// Панель аккаунта Claude: статус + вход/выход/переключение.
/// Генерация работает на локально залогиненном `claude` CLI, поэтому смена аккаунта здесь
/// влияет на «Generate with AI».
struct AccountView: View {
    @State private var manager = AccountManager()
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Claude Account", systemImage: "person.crop.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { Task { await manager.refresh() } } label: {
                    if manager.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .help("Refresh status")
                .disabled(manager.busy)
            }

            statusCard

            if !manager.message.isEmpty {
                Text(manager.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    manager.openLoginInTerminal()
                } label: {
                    Label(manager.status?.loggedIn == true ? "Switch account…" : "Log in…",
                          systemImage: "arrow.right.square")
                }
                Text("Sign-in opens in Terminal (browser OAuth). When it finishes, come back and Refresh.")
                    .font(.caption2).foregroundStyle(.tertiary)

                if manager.status?.loggedIn == true {
                    Button(role: .destructive) {
                        Task { await manager.logout() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(manager.busy)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
        .task { await manager.refresh() }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = manager.status {
                if s.loggedIn {
                    row("Email", s.email ?? "—")
                    row("Organization", s.orgName ?? "—")
                    row("Plan", (s.subscriptionType ?? "—").capitalized)
                    HStack(spacing: 6) {
                        Text("Endpoint").foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        if s.isFirstParty {
                            Label("Anthropic (direct)", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green).font(.caption)
                        } else {
                            Label("Custom relay (\(s.apiProvider ?? "?"))", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                    if !s.isFirstParty {
                        Text("Requests go through a custom endpoint set in ~/.claude/settings.json — switching accounts here may not change it.")
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.secondary)
                }
            } else if let err = manager.statusError {
                Text(err).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if manager.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
#endif
