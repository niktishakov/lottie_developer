#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Редактор проекта: превью + генерация (создаёт версию) + список версий с переходом.
struct EditorView: View {
    let store: ProjectStore
    let projectID: UUID
    var onClose: () -> Void

    @State private var previewURL: URL?
    @State private var selectedVersionID: UUID?
    @State private var status = ""
    @State private var loop = true
    @State private var speed: CGFloat = 1.0
    @State private var report: LottieRuntimeReport?
    @State private var prompt = "Animate this: stagger the elements in with a little overshoot, then add one subtle idle loop so it stays alive."
    @State private var generating = false
    @State private var dropTargeted = false

    private var project: AnimationProject? { store.project(projectID) }

    var body: some View {
        Group {
            if let project {
                HStack(spacing: 0) {
                    mainColumn(project)
                    Divider()
                    versionsSidebar(project)
                        .frame(width: 220)
                }
            } else {
                Text("Project not found").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadInitial() }
    }

    // MARK: - Main column

    private func mainColumn(_ project: AnimationProject) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { onClose() } label: { Label("Projects", systemImage: "chevron.left") }
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Replace SVG…") { openSVG() }
                Toggle("Loop", isOn: $loop)
            }

            HStack(spacing: 8) {
                Text("Speed")
                Slider(value: $speed, in: 0.25...3.0)
                Text(String(format: "%.2fx", speed)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                TextField("Describe the animation…", text: $prompt, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button {
                    generate()
                } label: {
                    if generating { ProgressView().controlSize(.small) } else { Text("Generate with AI") }
                }
                .disabled(generating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ZStack {
                CheckerboardBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let previewURL {
                    LottiePreviewView(fileURL: previewURL, loop: loop, speed: speed)
                        .id("\(previewURL.path)-\(loop)")
                        .padding(8)
                } else {
                    Text("Generate a version, or view the static geometry").foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 360, minHeight: 360)
            .overlay { if dropTargeted { dropHint } }

            Text(status.isEmpty ? "\(project.layerNames.count) layers · \(project.sourceLabel)" : status)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let report { reportPanel(report) }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            handleDropped(url: url); return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Versions sidebar

    private func versionsSidebar(_ project: AnimationProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Versions").font(.headline).padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    versionRow(title: "Static geometry",
                               subtitle: project.sourceLabel,
                               selected: selectedVersionID == nil) { showGeometry() }
                    ForEach(project.versions.sorted { $0.index > $1.index }) { v in
                        versionRow(title: v.label,
                                   subtitle: "\(v.layerCount) layers · \(v.compilerWarnings) warn\n\(v.prompt)",
                                   selected: selectedVersionID == v.id) { select(v) }
                    }
                }
                .padding(8)
            }
            if project.versions.isEmpty {
                Text("No versions yet.\nGenerate to create v1.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.09))
    }

    private func versionRow(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : Color(white: 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
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
                Text("\(report.fps)fps · \(report.durationFrames)f · \(report.renderingEngine) · \(report.sampledFrames) samples")
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.14)))
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
        report = previewURL.map { LottieRuntimeValidator.validate(fileURL: $0) }
        status = "Static geometry · \(project.layerNames.count) layers"
    }

    private func select(_ v: AnimationVersion) {
        selectedVersionID = v.id
        let url = store.versionURL(projectID, v.compiledFile)
        previewURL = url
        report = LottieRuntimeValidator.validate(fileURL: url)
        status = "Viewing \(v.label) · \(v.layerCount) layers"
    }

    private func generate() {
        guard let project, let geom = store.geometryData(for: project) else {
            status = "No geometry available"; return
        }
        let names = project.layerNames
        let request = prompt
        generating = true
        status = "Generating with claude (opus)…"
        Task {
            do {
                let (spec, _) = try await CLIProvider().generateSpec(request: request, layerNames: names, durationSeconds: 3)
                let result = try LottieCompiler().compile(staticLottie: geom, spec: spec)
                let specJSON = (try? JSONEncoder().encode(spec)).flatMap { String(data: $0, encoding: .utf8) }
                await MainActor.run {
                    if let v = store.addVersion(projectID: projectID, prompt: request, compiledData: result.data,
                                                layerCount: spec.layers.count, compilerWarnings: result.warnings.count,
                                                specJSON: specJSON) {
                        select(v)
                        status = "Generated \(v.label): \(spec.layers.count) layers, \(result.warnings.count) warning(s)"
                    }
                    generating = false
                }
            } catch {
                await MainActor.run {
                    status = "AI generation failed: \(error.localizedDescription)"
                    generating = false
                }
            }
        }
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

    private func handleDropped(url: URL) {
        switch url.pathExtension.lowercased() {
        case "svg": importSVG(url: url)
        case "json", "lottie":
            previewURL = url
            report = LottieRuntimeValidator.validate(fileURL: url)
            status = "Previewing \(url.lastPathComponent) (not saved as a version)"
        default:
            status = "Unsupported '.\(url.pathExtension)' — drop an .svg"
        }
    }
}

/// Шахматная подложка превью — чтобы рисунок любого цвета (в т.ч. чёрный) был виден.
private struct CheckerboardBackground: View {
    var cell: CGFloat = 10
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            let cols = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for r in 0..<max(rows, 1) {
                for c in 0..<max(cols, 1) where (r + c).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(Color(white: 0.32)))
                }
            }
        }
    }
}
#endif
