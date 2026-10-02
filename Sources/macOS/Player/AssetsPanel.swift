#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Папка ассетов проекта как в Finder: превью, добавить (перетащить / Add… / положить в папку), поставить в сцену, в Корзину.
/// Та же папка доступна Claude через MCP (`list_assets`, `add_assets`, `place_asset`, `delete_asset`).
struct AssetsPanel: View {
    let store: ProjectStore
    let projectID: UUID
    var onSceneChanged: (String) -> Void
    var onStatus: (String) -> Void

    @State private var dropTargeted = false
    @State private var selection: String?

    private var items: [AssetFiles.Item] {
        _ = store.feedbackRevision // перечитать при изменениях папки (Finder, MCP)
        return store.assets(projectID: projectID)
    }
    private var usage: [String: [String]] {
        _ = store.feedbackRevision
        return store.assetUsage(projectID: projectID)
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { pick() } label: { Label("Add…", systemImage: "plus") }
                Button { NSWorkspace.shared.open(folder) } label: { Label("Folder", systemImage: "folder") }
                    .help("Open in Finder — files you put there show up here")
                Spacer()
                Text("\(items.count)").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { tile($0) }
                }
                .padding(8)
            }
            if items.isEmpty {
                Text("Drop SVG, PNG, JPEG, Lottie JSON or a .zip here. Double-click a file to put it into the scene.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropTargeted = $0 }
    }

    private var folder: URL {
        let dir = store.assetsDir(projectID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tile(_ f: AssetFiles.Item) -> some View {
        let used = usage[f.name] ?? []
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                CheckerboardBackground()
                AssetThumb(url: f.url, kind: f.kind, modified: f.modified).padding(4)
                if !used.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        .padding(3).help("In scene: \(used.joined(separator: ", "))")
                }
            }
            .frame(height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selection == f.name ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selection == f.name ? 2 : 1))
            Text(f.name).font(.caption2).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { place(f) }
        .onTapGesture { selection = f.name }
        .contextMenu {
            Button("Add to scene") { place(f) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(f) }
        }
        .help(used.isEmpty ? "\(f.name) — double-click to add to the scene" : "\(f.name) — in scene as \(used.joined(separator: ", "))")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.svg, .png, .jpeg, .webP, .heic, .json, .zip]
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        do {
            let added = try store.addAssets(projectID: projectID, urls)
            onStatus(added.isEmpty ? "No supported files" : "Added to assets: \(added.joined(separator: ", "))")
        } catch { onStatus("Add failed: \(error.localizedDescription)") }
    }

    private func place(_ f: AssetFiles.Item) {
        do {
            let (layer, warnings) = try store.placeAsset(projectID: projectID, name: f.name)
            onSceneChanged(layer)
            onStatus("Added \(layer) to the scene" + (warnings.isEmpty ? "" : " · " + warnings.joined(separator: "; ")))
        } catch { onStatus("Place failed: \(error.localizedDescription)") }
    }

    private func trash(_ f: AssetFiles.Item) {
        do {
            try store.trashAsset(projectID: projectID, name: f.name)
            onStatus("\(f.name) moved to Trash (layers in the scene stay)")
        } catch { onStatus("Trash failed: \(error.localizedDescription)") }
    }
}

/// Превью файла: картинки и SVG — системным рендером, Lottie — первым «живым» кадром.
private struct AssetThumb: View {
    let url: URL
    let kind: String
    let modified: Date
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: kind == "lottie" ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
        }
        .task(id: "\(url.path)|\(modified.timeIntervalSince1970)") { image = load() }
    }

    private func load() -> NSImage? {
        if kind == "lottie" {
            guard let data = try? Data(contentsOf: url), let a = try? FrameRenderer.decode(data),
                  let (img, _) = try? FrameRenderer.renderImage(animation: a, frame: Double(a.endFrame) / 2, size: 160, background: nil)
            else { return nil }
            return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        }
        return NSImage(contentsOf: url)
    }
}
#endif
