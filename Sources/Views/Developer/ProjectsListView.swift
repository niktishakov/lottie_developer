#if os(iOS)
import SwiftUI

/// Список проектов (те же данные, что на Mac): миниатюра, имя, «N versions · время».
struct ProjectsListView: View {
    let store: ProjectStore

    private var projects: [AnimationProject] {
        store.projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if projects.isEmpty {
                ContentUnavailableView("No projects yet",
                                       systemImage: "sparkles",
                                       description: Text("Connect Claude on the Claude tab and ask it to make an animation."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(projects) { p in
                            NavigationLink(value: p.id) { ProjectCard(store: store, project: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Projects")
    }
}

private struct ProjectCard: View {
    let store: ProjectStore
    let project: AnimationProject

    private var previewURL: URL? {
        if let v = project.versions.max(by: { $0.index < $1.index }) {
            return store.versionURL(project.id, v.compiledFile)
        }
        return store.geometryPreviewURL(for: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                DevBackgroundView(kind: .checker)
                DevLottieStill(url: previewURL).padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(project.name).font(.headline).lineLimit(1)
            Text("\(project.versions.count) versions · \(Self.relative.localizedString(for: project.updatedAt, relativeTo: .now))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()
}
#endif
