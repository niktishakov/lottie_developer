#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Главный экран — список проектов.
struct HomeView: View {
    let store: ProjectStore
    var onOpen: (UUID) -> Void

    @State private var dropTargeted = false
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var showAccount = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Button { showAccount = true } label: { Label("Account", systemImage: "person.crop.circle") }
                Button { _ = openSVGAsProject() } label: { Label("New from SVG…", systemImage: "square.and.arrow.down") }
                Button { pasteSVGAsProject() } label: { Label("Paste SVG", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v")
                Button {
                    let p = store.createSampleProject(name: "Untitled \(store.projects.count + 1)")
                    onOpen(p.id)
                } label: { Label("New", systemImage: "plus") }
                .keyboardShortcut("n")
            }
            .padding(20)

            if store.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.projects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "svg" }) else { return false }
            if let id = importSVGAsProject(url: url) { onOpen(id) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHint } }
        .sheet(isPresented: $showAccount) { AccountView(onClose: { showAccount = false }) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.title3.weight(.semibold))
            Text("Drag an SVG here, or create a new project.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectCard(_ project: AnimationProject) -> some View {
        Button {
            onOpen(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.16))
                    .frame(height: 110)
                    .overlay(
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    )
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(project.versions.count) version(s) · \(project.layerNames.count) layers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(project.sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.11)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") { renaming = project.id; renameText = project.name }
            Button("Delete", role: .destructive) { store.delete(projectID: project.id) }
        }
        .alert("Rename project", isPresented: Binding(get: { renaming == project.id }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { store.rename(projectID: project.id, to: renameText); renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .overlay(Text("Drop an SVG to create a project").font(.headline).foregroundStyle(Color.accentColor))
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: - SVG → project

    private func openSVGAsProject() -> UUID? {
        let panel = NSOpenPanel()
        if let t = UTType(filenameExtension: "svg") { panel.allowedContentTypes = [t] }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let id = importSVGAsProject(url: url)
        if let id { onOpen(id) }
        return id
    }

    private func pasteSVGAsProject() {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: .string),
              str.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return }
        guard let data = str.data(using: .utf8) else { return }
        guard let result = try? SVGToLottie.convert(svgData: data) else { return }
        let p = store.createProjectFromSVG(name: "Pasted SVG", svgStaticData: result.data,
                                            layerNames: result.layerNames, sourceLabel: "clipboard")
        onOpen(p.id)
    }

    @discardableResult
    private func importSVGAsProject(url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let result = try? SVGToLottie.convert(svgData: data) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let p = store.createProjectFromSVG(name: name, svgStaticData: result.data,
                                            layerNames: result.layerNames, sourceLabel: url.lastPathComponent)
        return p.id
    }
}
#endif
