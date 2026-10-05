#if os(iOS)
import SwiftUI
import UIKit

/// Экран подключения Claude Code (Windows/ПК) к iPhone по Wi-Fi.
struct ClaudeConnectView: View {
    let server: CompanionServer
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                pinCard
                stepsCard
                commandCard
                activityCard
                Label("Keep this app open while working with Claude.", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Claude")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { server.refreshAddresses() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 14, height: 14)
                Text(statusText).font(.title2.bold())
            }
            if let error = server.error {
                Text(error).font(.callout).foregroundStyle(.red)
                Button("Try again") { server.stop(); server.start() }
                    .buttonStyle(.borderedProminent)
            }
            relayRow
            Text("iPhone address").font(.caption).foregroundStyle(.secondary)
            Text(server.viewerURL)
                .font(.title3.monospaced()).textSelection(.enabled)
            if server.addresses.isEmpty, server.relay?.state != .online {
                Text("No Wi-Fi address. Connect the iPhone to the same Wi-Fi as your PC.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .devCard()
    }

    /// Посредник в интернете: с ним Claude подключается с любого ПК, без общей Wi-Fi сети.
    private var relayRow: some View {
        let state = server.relay?.state ?? .off
        let (color, text): (Color, String) = switch state {
        case .online: (.green, "Online: works from any network")
        case .connecting: (.orange, "Connecting to the internet relay…")
        case .failed(let message): (.red, message)
        case .off: (.gray, "Internet relay is off. Same Wi-Fi only.")
        }
        return Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: "globe").foregroundStyle(color)
        }
    }

    private var statusColor: Color {
        server.error != nil ? .red : (server.isRunning ? .green : .gray)
    }
    private var statusText: String {
        server.error != nil ? "Server error" : (server.isRunning ? "Server running" : "Server stopped")
    }

    private var pinCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PIN").font(.caption).foregroundStyle(.secondary)
            Text(server.pin.map(String.init).joined(separator: " "))
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5).lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .devCard()
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to connect").font(.headline)
            step(1, "On your PC open \(server.viewerURL)/pair in a browser.")
            step(2, "Enter the PIN shown above.")
            step(3, "Copy the command from the page (or below) into Claude Code.")
            step(4, "Start a new Claude session.")
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
            Text("Claude Code command").font(.headline)
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

    private var activityCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                Label(activity("Claude", server.lastMCPAt, now: ctx.date),
                      systemImage: server.lastMCPAt == nil ? "circle.dashed" : "checkmark.circle.fill")
                Label(activity("Browser", server.lastViewerAt, now: ctx.date), systemImage: "globe")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .devCard()
    }

    private func activity(_ who: String, _ date: Date?, now: Date) -> String {
        guard let date else { return "\(who) not connected yet" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        let ago = s < 60 ? "\(s) s" : (s < 3600 ? "\(s / 60) min" : "\(s / 3600) h")
        return "\(who) connected \(ago) ago"
    }
}

extension View {
    func devCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemBackground)))
    }
}
#endif
