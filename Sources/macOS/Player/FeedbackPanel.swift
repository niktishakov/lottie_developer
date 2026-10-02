#if os(macOS)
import SwiftUI

/// Комментарии дизайнера: привязаны к версии, кадру и (если выбран) слою.
/// Claude читает их через MCP (`get_feedback`) и отвечает (`resolve_feedback`).
struct FeedbackPanel: View {
    let store: ProjectStore
    let projectID: UUID
    let player: PlayerModel
    /// Текущая версия (nil — статичная геометрия) и её метка.
    let versionID: UUID?
    let versionLabel: String
    var onJump: (FeedbackItem) -> Void

    @State private var draft = ""
    @State private var showResolved = false

    private var items: [FeedbackItem] {
        _ = store.feedbackRevision // подписка на изменения с диска (ответы Claude)
        return store.feedback(projectID: projectID)
            .filter { showResolved || !$0.resolved }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Comment for Claude…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                HStack {
                    FeedbackTarget(player: player, versionLabel: versionLabel)
                    Spacer()
                    Button("Add", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)

            Divider()
            HStack {
                Toggle("Show resolved", isOn: $showResolved).font(.caption)
                Spacer()
                let open = store.feedback(projectID: projectID).filter { !$0.resolved }.count
                Text("\(open) open").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { row($0) }
                }
                .padding(8)
            }
            if items.isEmpty {
                Text("No comments. Pause on a frame, select a layer if needed, and write what to change.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addFeedback(projectID: projectID, FeedbackItem(
            versionID: versionID, versionLabel: versionLabel, frame: Int(player.frame.rounded()),
            layer: player.selectedLayer, text: text))
        draft = ""
    }

    private func row(_ f: FeedbackItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: f.resolved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(f.resolved ? .green : .orange)
                Text("\(f.versionLabel) · f\(f.frame)\(f.layer.map { " · \($0)" } ?? "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            Text(f.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let reply = f.reply, !reply.isEmpty {
                Text("Claude: \(reply)").font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { onJump(f) }
        .contextMenu {
            Button(f.resolved ? "Reopen" : "Mark resolved") {
                _ = store.resolveFeedback(projectID: projectID, id: f.id, reply: nil, resolved: !f.resolved)
            }
            Button("Delete", role: .destructive) { store.deleteFeedback(projectID: projectID, id: f.id) }
        }
    }
}

/// «v3 · f40 · shield» — куда привяжется комментарий. Отдельная вью: обновляется на каждый тик.
private struct FeedbackTarget: View {
    let player: PlayerModel
    let versionLabel: String
    var body: some View {
        Text("\(versionLabel) · f\(Int(player.frame.rounded()))\(player.selectedLayer.map { " · \($0)" } ?? "")")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
    }
}
#endif
