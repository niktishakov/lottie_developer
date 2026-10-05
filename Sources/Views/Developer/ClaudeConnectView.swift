#if os(iOS)
import SwiftUI
import UIKit

/// Экран Claude: подключён ли Claude, PIN для нового компьютера, что Claude сейчас делает. Инструкции свёрнуты.
struct ClaudeConnectView: View {
    let server: CompanionServer
    @State private var copied = false
    @State private var showSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in statusCard(now: ctx.date) }
                pairCard
                activityCard
                DisclosureGroup("Setup steps and command", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 16) {
                        stepsCard
                        commandCard
                    }
                    .padding(.top, 12)
                }
                .font(.callout).tint(.secondary)
                .padding(.horizontal, 4)
                Label("Keep this app open on screen while the agent works. If it's closed, the agent sees “iPhone is offline”.", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Agent")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { server.refreshAddresses() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }

    // MARK: - Статус

    private var isOnline: Bool { server.relay?.state == .online }

    private enum Status { case connected(Date), ready, connecting, wifiOnly, error(String) }

    /// Claude обращался меньше минуты назад — «подключён», иначе «готов» и ждёт.
    private func status(now: Date) -> Status {
        if let e = server.error { return .error(e) }
        if let t = server.lastMCPAt, now.timeIntervalSince(t) < 60 { return .connected(t) }
        switch server.relay?.state ?? .off {
        case .online: return .ready
        case .connecting: return .connecting
        case .failed, .off: return .wifiOnly
        }
    }

    private func statusCard(now: Date) -> some View {
        let s = status(now: now)
        let (title, detail, color, icon): (String, String, Color, String) = switch s {
        case .connected(let t): ("Agent connected", "Last request \(Self.ago(t, now: now)) ago · works from any network", .green, "bolt.horizontal.circle.fill")
        case .ready: ("Ready for agent", "Online. Your computer can be on any network.", .green, "checkmark.circle.fill")
        case .connecting: ("Connecting…", "Connecting to the internet.", .orange, "arrow.triangle.2.circlepath")
        case .wifiOnly: ("Wi-Fi only", relayMessage, .orange, "wifi")
        case .error(let e): ("Server error", e, .red, "exclamationmark.triangle.fill")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.title3.bold()).foregroundStyle(color)
            Text(detail).font(.callout).foregroundStyle(color.opacity(0.8))
            if case .error = s {
                Button("Try again") { server.stop(); server.start() }.buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(color.opacity(0.16)))
    }

    private var relayMessage: String {
        if case .failed(let m) = server.relay?.state ?? .off { return "\(m) The computer must be on the same Wi-Fi." }
        return server.addresses.isEmpty ? "No internet and no Wi-Fi. Check the connection." : "The computer must be on the same Wi-Fi."
    }

    // MARK: - PIN

    private var pairCard: some View {
        VStack(spacing: 8) {
            Text("To connect a new computer, open").font(.callout).foregroundStyle(.secondary)
            Text(server.pairURL).font(.headline).textSelection(.enabled).multilineTextAlignment(.center)
            Text(Self.groupedPIN(server.pin))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5).lineLimit(1).textSelection(.enabled)
                .padding(.top, 6)
            Text("New PIN after each pairing").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .devCard()
    }

    static func groupedPIN(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }

    // MARK: - Лента

    private var activityCard: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text("Activity").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    .padding(.bottom, 8)
                if server.activity.isEmpty {
                    Text("The agent hasn't done anything yet. Ask it to make an animation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(server.activity.prefix(6).enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider() }
                    HStack {
                        Text(item.count > 1 ? "\(item.text) ×\(item.count)" : item.text)
                        Spacer()
                        Text(Self.ago(item.at, now: ctx.date)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .devCard()
    }

    // MARK: - Инструкции (свёрнуты)

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isOnline {
                Text("The computer must be on the same Wi-Fi as this iPhone.").font(.callout).foregroundStyle(.orange)
            }
            step(1, "On your computer open \(server.pairURL) in a browser.")
            step(2, "Enter the PIN shown above.")
            step(3, "Copy the command from the page. Paste it into PowerShell (Windows) or Terminal (Mac) and press Enter.")
            step(4, "Restart your agent app (Claude, Cursor, VS Code…). On Windows also close it in the tray.")
        }
        .devCard()
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.headline.monospacedDigit())
                .frame(width: 26, height: 26).background(Circle().fill(.tint.opacity(0.25)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or copy the command here").font(.headline)
            Text("Handy on a Mac with the same Apple ID: it pastes on the Mac right away.")
                .font(.callout).foregroundStyle(.secondary)
            Text(server.mcpCommand)
                .font(.caption.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
            HStack {
                Button {
                    UIPasteboard.general.string = server.mcpCommand
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderedProminent)
                ShareLink(item: server.mcpCommand) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        }
        .devCard()
    }

    /// «2 s», «5 min», «3 h». Будущее время (часы чуть разошлись) считаем «0 s».
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        return s < 60 ? "\(s) s" : (s < 3600 ? "\(s / 60) min" : "\(s / 3600) h")
    }
}

extension View {
    func devCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
    }
}
#endif
