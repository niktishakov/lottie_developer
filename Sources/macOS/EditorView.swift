#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Редактор проекта: превью + список версий. Версии создаются извне через MCP (lottie-mcp).
struct EditorView: View {
    let store: ProjectStore
    let projectID: UUID
    var command: ProjectStore.UICommand? = nil
    var onClose: () -> Void

    @State private var previewURL: URL?
    @State private var selectedVersionID: UUID?
    @State private var status = ""
    @State private var player = PlayerModel()
    @State private var compareVersionID: UUID?
    @State private var comparing = false
    @State private var frameCostMs: Double?
    @State private var report: LottieRuntimeReport?
    @State private var dropTargeted = false
    @State private var multiSelection: Set<UUID> = []

    private var project: AnimationProject? { store.project(projectID) }

    var body: some View {
        Group {
            if let project {
                HStack(spacing: 0) {
                    LayersPanel(model: player)
                        .frame(width: 200)
                    Divider()
                    mainColumn(project)
                    Divider()
                    VStack(spacing: 0) {
                        InspectorPanel(model: player, onSaveVersion: saveEdits)
                        Divider()
                        versionsSidebar(project)
                    }
                    .frame(width: 240)
                }
            } else {
                Text("Project not found").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { player.startClock(); loadInitial(); apply(command) }
        .onDisappear { player.stopClock() }
        .onChange(of: command) { _, cmd in apply(cmd) }
        .task { await publishState() }
        .onChange(of: project?.versions.map(\.id) ?? []) { old, new in
            // Новая версия пришла извне (MCP) — показываем её.
            if new.count > old.count, let latest = project?.versions.max(by: { $0.index < $1.index }) {
                select(latest)
            } else if let sel = selectedVersionID, !new.contains(sel) {
                loadInitial()
            }
        }
    }

    // MARK: - Main column

    private func mainColumn(_ project: AnimationProject) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { onClose() } label: { Label("Projects", systemImage: "chevron.left") }
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Import Lottie…") { openLottieJSON() }
                Button("Replace SVG…") { openSVG() }
                Button("Paste SVG") { pasteSVGFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Menu {
                    ForEach(Exporter.Kind.allCases) { k in Button(k.rawValue) { export(k, project) } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
            }

            viewOptions(project)

            HStack(spacing: 8) {
                stageColumn(label: comparing ? currentLabel(project) : nil, compare: false)
                if comparing {
                    stageColumn(label: player.compareLabel ?? "—", compare: true)
                }
            }
            .frame(minWidth: 360, minHeight: 320)
            .overlay { if dropTargeted { dropHint } }

            TimelineBar(model: player)
            FilmstripView(model: player)

            Text(status.isEmpty ? "\(project.layerNames.count) layers · \(project.sourceLabel)" : status)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let report { reportPanel(report) }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            handleDropped(url: url); return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func viewOptions(_ project: AnimationProject) -> some View {
        HStack(spacing: 10) {
            Picker("Background", selection: $player.backdrop) {
                ForEach(PlayerModel.Backdrop.allCases) { Text($0.rawValue).tag($0) }
            }.fixedSize()
            Picker("Preview", selection: $player.stage) {
                ForEach(PlayerModel.Stage.allCases) { Text($0.rawValue).tag($0) }
            }.fixedSize()
            Picker("Engine", selection: $player.engine) {
                ForEach(PlayerModel.Engine.allCases) { Text($0.rawValue).tag($0) }
            }.fixedSize()
            Toggle("Reduced motion", isOn: $player.reducedMotion)
            Spacer()
            Menu {
                Button("Off") { comparing = false; player.loadCompare(data: nil, label: nil) }
                Divider()
                Button("Static geometry") { startCompare(nil, project) }
                ForEach(project.versions.sorted { $0.index > $1.index }) { v in
                    Button(v.label) { startCompare(v.id, project) }
                }
            } label: {
                Label(comparing ? "Compare: \(player.compareLabel ?? "")" : "Compare", systemImage: "rectangle.split.2x1")
            }
            .fixedSize()
        }
        .font(.callout)
    }

    private func stageColumn(label: String?, compare: Bool) -> some View {
        VStack(spacing: 4) {
            if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            CanvasStage(model: player, compare: compare)
        }
    }

    private func currentLabel(_ project: AnimationProject) -> String {
        project.versions.first { $0.id == selectedVersionID }?.label ?? "Static geometry"
    }

    // MARK: - Versions sidebar

    private func versionsSidebar(_ project: AnimationProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Versions").font(.headline)
                Spacer()
                if !multiSelection.isEmpty {
                    Button(role: .destructive) { deleteSelected() } label: {
                        Label("Delete \(multiSelection.count)", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    versionRow(title: "Static geometry",
                               subtitle: project.sourceLabel,
                               selected: selectedVersionID == nil,
                               multiSelected: false) { showGeometry() }
                    ForEach(project.versions.sorted { lhs, rhs in
                        if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
                        return lhs.index > rhs.index
                    }) { v in
                        versionRow(title: v.label,
                                   subtitle: "\(v.layerCount) layers · \(v.compilerWarnings) warn\n\(v.prompt)",
                                   selected: selectedVersionID == v.id,
                                   isFavourite: v.isFavourite,
                                   multiSelected: multiSelection.contains(v.id)) {
                            if NSEvent.modifierFlags.contains(.command) {
                                toggleMultiSelection(v.id)
                            } else {
                                multiSelection.removeAll()
                                select(v)
                            }
                        }
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(v.prompt, forType: .string)
                            } label: {
                                Label("Copy Prompt", systemImage: "doc.on.doc")
                            }
                            Button {
                                store.toggleFavourite(projectID: projectID, versionID: v.id)
                            } label: {
                                Label(v.isFavourite ? "Unfavourite" : "Favourite",
                                      systemImage: v.isFavourite ? "star.slash" : "star.fill")
                            }
                            if multiSelection.count > 1 {
                                Button("Delete \(multiSelection.count) selected", role: .destructive) { deleteSelected() }
                            }
                            Button("Delete", role: .destructive) { deleteVersion(v) }
                        }
                    }
                }
                .padding(8)
            }
            if project.versions.isEmpty {
                Text("No versions yet.\nCreate one via MCP (lottie-mcp).")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func versionRow(title: String, subtitle: String, selected: Bool, isFavourite: Bool = false, multiSelected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !multiSelection.isEmpty {
                    Image(systemName: multiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(multiSelected ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.subheadline.weight(.semibold))
                        if isFavourite {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : multiSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : multiSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Report panel

    @ViewBuilder
    private func reportPanel(_ report: LottieRuntimeReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(report.passed ? "Runtime: PASS" : "Runtime: FAIL",
                      systemImage: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.passed ? .green : .orange)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(report.fps)fps · \(report.durationFrames)f · \(report.renderingEngine) · \(report.sampledFrames) samples · live: \(player.activeEngine)\(frameCostMs.map { String(format: " · %.1f ms/frame", $0) } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(report.findings) { f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(f.severity.rawValue.uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(color(for: f.severity))
                        .frame(width: 64, alignment: .leading)
                    Text(f.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func color(for severity: LottieValidationFinding.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .secondary
        case .info: return .green
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .background(Color.accentColor.opacity(0.08))
            .overlay(Text("Drop an SVG to replace geometry").font(.headline).foregroundStyle(Color.accentColor))
            .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func loadInitial() {
        guard let project else { return }
        if let latest = project.versions.max(by: { $0.index < $1.index }) {
            select(latest)
        } else {
            showGeometry()
        }
    }

    private func showGeometry() {
        guard let project else { return }
        selectedVersionID = nil
        previewURL = store.geometryPreviewURL(for: project)
        player.load(data: previewURL.flatMap { try? Data(contentsOf: $0) })
        report = previewURL.map { LottieRuntimeValidator.validate(fileURL: $0) }
        frameCostMs = player.measureFrameCost()
        status = "Static geometry · \(project.layerNames.count) layers"
    }

    private func select(_ v: AnimationVersion) {
        selectedVersionID = v.id
        let url = store.versionURL(projectID, v.compiledFile)
        previewURL = url
        player.load(data: try? Data(contentsOf: url))
        report = LottieRuntimeValidator.validate(fileURL: url)
        frameCostMs = player.measureFrameCost()
        status = "Viewing \(v.label) · \(v.layerCount) layers"
    }

    /// Команда из MCP (show_in_app): версия, кадр, слой.
    private func apply(_ cmd: ProjectStore.UICommand?) {
        guard let cmd else { return }
        if let id = cmd.versionID, let v = project?.versions.first(where: { $0.id == id }), v.id != selectedVersionID { select(v) }
        if let f = cmd.frame { player.seek(f) }
        if let l = cmd.layer { player.select(l) }
        if let t = cmd.tap, t.count == 2 { player.tap(atComp: CGPoint(x: t[0], y: t[1])) }
    }

    /// Публикуем состояние UI для lottie-mcp раз в 0.5 с (только при изменениях).
    private func publishState() async {
        var last: ProjectStore.AppState?
        while !Task.isCancelled {
            let st = ProjectStore.AppState(
                projectID: projectID, projectName: project?.name,
                version: project?.versions.first { $0.id == selectedVersionID }?.label ?? "geometry",
                frame: player.frame.rounded(), playing: player.isPlaying, mode: player.mode.rawValue,
                engine: player.engine.rawValue, activeEngine: player.activeEngine,
                selectedLayer: player.selectedLayer, overrides: player.overrides, updatedAt: last?.updatedAt ?? Date())
            if st != last {
                var out = st; out.updatedAt = Date()
                store.writeAppState(out)
                last = st
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func startCompare(_ versionID: UUID?, _ project: AnimationProject) {
        let data: Data?
        let label: String
        if let versionID, let v = project.versions.first(where: { $0.id == versionID }) {
            data = try? Data(contentsOf: store.versionURL(projectID, v.compiledFile)); label = v.label
        } else {
            data = store.geometryData(for: project); label = "Static geometry"
        }
        compareVersionID = versionID
        player.loadCompare(data: data, label: label)
        comparing = true
    }

    private func saveEdits() {
        guard let project, let data = player.displayData, player.hasEdits else { return }
        let parent = project.versions.first { $0.id == selectedVersionID }
        let summary = player.overrides.sorted { $0.key < $1.key }.map { name, o in
            var parts: [String] = []
            if let c = o.color { parts.append("color \(c)") }
            if let op = o.opacity { parts.append("opacity \(Int(op))%") }
            if o.hidden { parts.append("hidden") }
            return "\(name): " + parts.joined(separator: ", ")
        }.joined(separator: "; ")
        let base = parent?.label ?? "geometry"
        if let v = store.addVersion(projectID: projectID, prompt: "Edits on \(base): \(summary)", compiledData: data,
                                    layerCount: parent?.layerCount ?? player.layers.count, compilerWarnings: 0,
                                    specJSON: nil, parentVersionID: parent?.id, note: summary, source: "edit") {
            select(v)
            status = "Saved \(v.label) from inspector edits"
        }
    }

    private func export(_ kind: Exporter.Kind, _ project: AnimationProject) {
        guard let data = player.displayData else { status = "Nothing to export"; return }
        let base = "\(project.name)_\(currentLabel(project))".replacingOccurrences(of: " ", with: "_")
        let bg: NSColor? = player.backdrop == .dark ? NSColor(white: 0.07, alpha: 1) : player.backdrop == .light ? .white : nil
        do {
            if let msg = try Exporter.run(kind, data: data, frame: player.frame, baseName: base, background: bg) { status = msg }
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func toggleMultiSelection(_ id: UUID) {
        if multiSelection.contains(id) {
            multiSelection.remove(id)
        } else {
            multiSelection.insert(id)
        }
    }

    private func deleteSelected() {
        for id in multiSelection {
            store.deleteVersion(projectID: projectID, versionID: id)
        }
        if let sel = selectedVersionID, multiSelection.contains(sel) {
            showGeometry()
        }
        multiSelection.removeAll()
    }

    private func deleteVersion(_ v: AnimationVersion) {
        store.deleteVersion(projectID: projectID, versionID: v.id)
        multiSelection.remove(v.id)
        if selectedVersionID == v.id {
            showGeometry()
        }
    }

    private func openLottieJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["layers"] != nil else {
            status = "Not a valid Lottie JSON"
            return
        }
        store.setImportedLottie(projectID: projectID, data: data, sourceLabel: url.lastPathComponent)
        showGeometry()
        let names = store.project(projectID)?.layerNames ?? []
        status = "Imported Lottie: \(names.count) layers"
    }

    private func openSVG() {
        let panel = NSOpenPanel()
        if let t = UTType(filenameExtension: "svg") { panel.allowedContentTypes = [t] }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSVG(url: url)
    }

    private func importSVG(url: URL) {
        guard let data = try? Data(contentsOf: url) else { status = "Could not read \(url.lastPathComponent)"; return }
        do {
            let result = try SVGToLottie.convert(svgData: data)
            store.setImportedStatic(projectID: projectID, data: result.data,
                                    layerNames: result.layerNames, sourceLabel: url.lastPathComponent)
            showGeometry()
            let warn = result.warnings.isEmpty ? "" : " · \(result.warnings.count) warning(s)"
            status = "Replaced geometry: \(result.layerNames.count) named layers\(warn)"
        } catch {
            status = "SVG import failed: \(error.localizedDescription)"
        }
    }

    private func pasteSVGFromClipboard() {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: .string),
              str.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
            status = "Clipboard does not contain SVG"; return
        }
        guard let data = str.data(using: .utf8) else { status = "Could not read clipboard"; return }
        do {
            let result = try SVGToLottie.convert(svgData: data)
            store.setImportedStatic(projectID: projectID, data: result.data,
                                    layerNames: result.layerNames, sourceLabel: "clipboard")
            showGeometry()
            let warn = result.warnings.isEmpty ? "" : " · \(result.warnings.count) warning(s)"
            status = "Pasted SVG: \(result.layerNames.count) named layers\(warn)"
        } catch {
            status = "SVG paste failed: \(error.localizedDescription)"
        }
    }

    private func handleDropped(url: URL) {
        switch url.pathExtension.lowercased() {
        case "svg": importSVG(url: url)
        case "json", "lottie":
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["layers"] != nil else {
                status = "Not a valid Lottie JSON"
                return
            }
            store.setImportedLottie(projectID: projectID, data: data, sourceLabel: url.lastPathComponent)
            showGeometry()
            let names = store.project(projectID)?.layerNames ?? []
            status = "Imported Lottie: \(names.count) layers"
        default:
            status = "Unsupported '.\(url.pathExtension)' — drop an .svg"
        }
    }
}

#endif
