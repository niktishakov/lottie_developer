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
    @State private var query = ""

    private var filtered: [AnimationProject] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.projects : store.projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button { openImagesAsProject() } label: { Label("New from images…", systemImage: "photo.on.rectangle") }
                Button { openLottieAsProject() } label: { Label("Import Lottie…", systemImage: "doc.badge.arrow.up") }
                Button { _ = openSVGAsProject() } label: { Label("New from SVG…", systemImage: "square.and.arrow.down") }
                Button { pasteSVGAsProject() } label: { Label("Paste SVG", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
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
                        ForEach(filtered) { project in
                            projectCard(project)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty {
                if let id = createProject(fromImages: images) { onOpen(id) }
                return true
            }
            if let url = urls.first(where: { $0.pathExtension.lowercased() == "json" }) {
                if let id = importLottieAsProject(url: url) { onOpen(id) }
                return true
            }
            if let url = urls.first(where: { $0.pathExtension.lowercased() == "svg" }) {
                if let id = importSVGAsProject(url: url) { onOpen(id) }
                return true
            }
            return false
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHint } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.title3.weight(.semibold))
            Text("Drag an SVG or Lottie JSON here, or create a new project.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewVersion(for project: AnimationProject) -> AnimationVersion? {
        project.versions.first(where: { $0.isFavourite }) ?? project.versions.max(by: { $0.index < $1.index })
    }

    private func projectCard(_ project: AnimationProject) -> some View {
        Button { onOpen(project.id) } label: {
            ProjectCard(project: project, previewURL: previewURL(for: project))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { onOpen(project.id) }
            Button("Rename") { renaming = project.id; renameText = project.name }
            Button("Duplicate") { store.duplicate(projectID: project.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.projectDir(project.id)]) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(projectID: project.id) }
        }
        .alert("Rename project", isPresented: Binding(get: { renaming == project.id }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { store.rename(projectID: project.id, to: renameText); renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func previewURL(for project: AnimationProject) -> URL? {
        if let v = previewVersion(for: project) { return store.versionURL(project.id, v.compiledFile) }
        return store.geometryPreviewURL(for: project)
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]

    private func openImagesAsProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if let id = createProject(fromImages: panel.urls) { onOpen(id) }
    }

    /// Новый растровый проект: холст по самой большой картинке, каждая картинка — слой.
    private func createProject(fromImages urls: [URL]) -> UUID? {
        let sized = urls.compactMap { url in (try? Data(contentsOf: url)).flatMap(LottieImageLayers.pixelSize).map { (url, $0) } }
        guard let first = urls.first,
              let px = sized.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })?.1 else { return nil }
        let name = store.uniqueName(first.deletingPathExtension().lastPathComponent)
        let p = store.createBlankProject(name: name, width: px.width, height: px.height)
        // Первая — верхний слой: добавляем с конца (каждая новая ложится сверху).
        for url in urls.reversed() {
            guard let data = try? Data(contentsOf: url) else { continue }
            _ = try? store.addImage(projectID: p.id, image: data, name: url.deletingPathExtension().lastPathComponent)
        }
        return p.id
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .overlay(Text("Drop SVG, Lottie or images to create a project").font(.headline).foregroundStyle(Color.accentColor))
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: - Lottie JSON → project

    private func openLottieAsProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id = importLottieAsProject(url: url) { onOpen(id) }
    }

    @discardableResult
    private func importLottieAsProject(url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["layers"] != nil else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let p = store.createProjectFromLottie(name: name, lottieData: data, sourceLabel: url.lastPathComponent)
        return p.id
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
        let p = store.createProjectFromSVG(name: store.uniqueName(SVGToLottie.title(svgData: data) ?? "SVG"), svgStaticData: result.data,
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
/// Карточка проекта: в покое — статичный «лучший» кадр, при наведении — анимация.
private struct ProjectCard: View {
    let project: AnimationProject
    let previewURL: URL?
    @State private var hovering = false
    @State private var still: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                CheckerboardBackground()
                if hovering, let previewURL {
                    LottiePreviewView(fileURL: previewURL, loop: true, speed: 1).padding(6)
                } else if let still {
                    Image(nsImage: still).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.1)))

            Text(project.name).font(.headline).lineLimit(1).padding(.top, 4)
            Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: stillKey) { still = previewURL.flatMap(StillCache.image(for:)) }
    }

    private var stillKey: String { "\(previewURL?.path ?? "")|\(project.updatedAt.timeIntervalSince1970)" }

    private var meta: String {
        let n = project.versions.count
        let versions = n == 0 ? "No versions" : n == 1 ? "1 version" : "\(n) versions"
        let now = Date()
        guard now.timeIntervalSince(project.updatedAt) >= 60 else { return "\(versions) · just now" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        return "\(versions) · \(rel.localizedString(for: project.updatedAt, relativeTo: now))"
    }
}

/// Статичные превью: из нескольких кадров берём тот, где больше всего нарисовано
/// (у многих анимаций кадр 0 пустой). Кэш по пути и времени изменения файла.
@MainActor
private enum StillCache {
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL) -> NSImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let img = cache[key] { return img }
        guard let data = try? Data(contentsOf: url), let anim = try? FrameRenderer.decode(data) else { return nil }
        let start = Double(anim.startFrame), end = Double(anim.endFrame)
        var best: (CGImage, Double)?
        for i in 0..<6 {
            let f = start + (end - start) * Double(i) / 5
            guard let (img, scale) = try? FrameRenderer.renderImage(animation: anim, frame: f, size: 240, background: nil) else { continue }
            let area = Double(FrameRenderer.opaqueBounds(img, scale: scale).map { $0.width * $0.height } ?? 0)
            if best == nil || area > best!.1 { best = (img, area) }
        }
        guard let (img, _) = best else { return nil }
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        cache[key] = ns
        return ns
    }
}
#endif
