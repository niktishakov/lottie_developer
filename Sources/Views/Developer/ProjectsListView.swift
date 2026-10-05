#if os(iOS)
import SwiftUI

/// Список проектов: свежий проект — большой карточкой, остальные — строками.
/// Видно, что нового сделал Claude: метка «New from Claude», заметка версии, длительность, открытые комментарии.
struct ProjectsListView: View {
    let store: ProjectStore
    var claudeOnline = false

    private var projects: [AnimationProject] {
        store.projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let first = projects.first {
                    NavigationLink(value: first.id) { ProjectHeroCard(store: store, project: first) }
                        .buttonStyle(.plain)
                }
                ForEach(projects.dropFirst()) { p in
                    NavigationLink(value: p.id) { ProjectRow(store: store, project: p) }
                        .buttonStyle(.plain)
                }
                startCard
            }
            .padding()
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ClaudeStatusPill(online: claudeOnline) }
        }
    }

    private var startCard: some View {
        VStack(spacing: 4) {
            Text(projects.isEmpty ? "Ask your agent to make an animation" : "Ask your agent to start a project")
            Text("Connect an agent on the Agent tab, then describe what should move.").font(.footnote)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(22)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.quaternary))
    }
}

struct ClaudeStatusPill: View {
    let online: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(online ? "Agent online" : "Offline").font(.footnote.weight(.semibold))
        }
        .foregroundStyle(online ? Color.green : Color.secondary)
        .padding(.horizontal, 6)
    }
}

// MARK: - Карточки

private struct ProjectHeroCard: View {
    let store: ProjectStore
    let project: AnimationProject

    var body: some View {
        let info = ProjectInfo(store: store, project: project)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                DevBackgroundView(kind: .checker)
                DevLottieStill(url: info.previewURL, fill: true)
            }
            .frame(height: 210)
            .clipped()
            .overlay(alignment: .topLeading) {
                if info.isNew { Badge(text: "New from agent", fill: .blue).padding(12) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = info.durationText { Badge(text: d, fill: .black.opacity(0.6)).padding(12) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if info.openComments > 0 { CommentsBadge(count: info.openComments) }
                }
                Text(info.subtitle).font(.subheadline).foregroundStyle(.secondary)
                if let note = info.note {
                    Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).padding(.top, 2)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct ProjectRow: View {
    let store: ProjectStore
    let project: AnimationProject

    var body: some View {
        let info = ProjectInfo(store: store, project: project)
        HStack(spacing: 12) {
            ZStack {
                DevBackgroundView(kind: .checker)
                DevLottieStill(url: info.previewURL).padding(4)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name).font(.headline).lineLimit(1)
                    if info.isNew { Circle().fill(.blue).frame(width: 8, height: 8) }
                }
                Text(info.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if info.openComments > 0 { CommentsBadge(count: info.openComments) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemBackground)))
    }
}

private struct Badge: View {
    let text: String
    let fill: Color
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(fill))
    }
}

private struct CommentsBadge: View {
    let count: Int
    var body: some View {
        Text(count == 1 ? "1 comment" : "\(count) comments")
            .font(.footnote.weight(.semibold)).foregroundStyle(.red)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.red.opacity(0.18)))
    }
}

// MARK: - Данные карточки

/// Всё, что карточка показывает о проекте.
@MainActor
struct ProjectInfo {
    let previewURL: URL?
    let subtitle: String
    let note: String?
    let durationText: String?
    let isNew: Bool
    let openComments: Int

    init(store: ProjectStore, project: AnimationProject) {
        let latest = project.versions.max(by: { $0.index < $1.index })
        previewURL = latest.map { store.versionURL(project.id, $0.compiledFile) } ?? store.geometryPreviewURL(for: project)
        let when = Self.relative(project.updatedAt)
        subtitle = latest.map { "\($0.label) · \(when)" } ?? "No versions yet · \(when)"
        let text = [latest?.note, latest?.prompt].compactMap { $0 }.first { !$0.isEmpty }
        note = text
        durationText = previewURL.flatMap(LottieDuration.text(for:))
        isNew = SeenVersions.isNew(project)
        _ = store.feedbackRevision
        openComments = store.feedback(projectID: project.id).filter { !$0.resolved }.count
    }

    /// «just now», «5 min ago», «2 days ago». Время из будущего (часы чуть разошлись) — «just now».
    static func relative(_ date: Date) -> String {
        let d = min(date, .now)
        if Date.now.timeIntervalSince(d) < 60 { return "just now" }
        return formatter.localizedString(for: d, relativeTo: .now)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()
}

/// Длительность Lottie по fr/ip/op, с кэшем по пути и дате изменения.
enum LottieDuration {
    @MainActor private static var cache: [String: String] = [:]

    @MainActor static func text(for url: URL) -> String? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let t = cache[key] { return t }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fr = (obj["fr"] as? NSNumber)?.doubleValue, fr > 0,
              let ip = (obj["ip"] as? NSNumber)?.doubleValue, let op = (obj["op"] as? NSNumber)?.doubleValue, op > ip
        else { return nil }
        let t = String(format: "%.1f s", (op - ip) / fr)
        cache[key] = t
        return t
    }
}

/// Какую версию дизайнер уже видел — для метки «New from Claude».
enum SeenVersions {
    private static let key = "projects.seenVersionIndex"

    private static var all: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isNew(_ p: AnimationProject) -> Bool {
        guard let latest = p.versions.map(\.index).max() else { return false }
        if let seen = all[p.id.uuidString] { return latest > seen }
        // Проекты до этой функции не помечаем «новыми», если им больше суток.
        return Date.now.timeIntervalSince(p.updatedAt) < 86_400
    }

    static func markSeen(_ p: AnimationProject) {
        guard let latest = p.versions.map(\.index).max() else { return }
        all[p.id.uuidString] = latest
    }
}
#endif
