import Foundation

/// Обработчик MCP-протокола и инструментов поверх `ProjectStore` + `LottieCompiler`.
@MainActor
final class MCPServer {
    let store = ProjectStore()

    private static let serverVersion = "1.0.0"
    private static let defaultProtocol = "2025-06-18"

    struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - JSON-RPC

    func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        // Нотификации (без id) — ответ не нужен.
        guard let id else { return nil }

        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }

        switch method {
        case "initialize":
            let proto = params["protocolVersion"] as? String ?? Self.defaultProtocol
            return ok([
                "protocolVersion": proto,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "lottie-developer", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            store.load() // приложение могло изменить данные
            do {
                let result = try callTool(name, args)
                if let r = result as? RenderedFrames {
                    var content: [[String: Any]] = [["type": "text", "text": Self.jsonString(r.meta)]]
                    content += r.images.map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/png"] }
                    return ok(["content": content, "isError": false])
                }
                return ok(["content": [["type": "text", "text": Self.jsonString(result)]], "isError": false])
            } catch {
                return ok(["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
            }
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    // MARK: - Tools dispatch

    private func callTool(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "get_guide": return guide()
        case "list_projects": return store.projects.map(projectSummary)
        case "get_project": return try projectDetails(try project(a))
        case "create_project": return try createProject(a)
        case "rename_project":
            let p = try project(a)
            store.rename(projectID: p.id, to: try str(a, "name"))
            return projectSummary(try project(a))
        case "delete_project":
            let p = try project(a)
            store.delete(projectID: p.id)
            return ["deleted": p.id.uuidString]
        case "replace_geometry": return try replaceGeometry(a)
        case "get_geometry": return try getGeometry(a)
        case "validate_spec": return try compileSpec(a, save: false)
        case "create_version": return try compileSpec(a, save: true)
        case "create_version_from_lottie": return try createVersionFromLottie(a)
        case "list_versions": return try project(a).versions.sorted { $0.index < $1.index }.map(versionSummary)
        case "get_version": return try getVersion(a)
        case "diff_versions": return try diffVersions(a)
        case "restore_version": return try restoreVersion(a)
        case "delete_version":
            let (p, v) = try version(a)
            store.deleteVersion(projectID: p.id, versionID: v.id)
            return ["deleted": v.label]
        case "set_favourite":
            let (p, v) = try version(a)
            let want = a["favourite"] as? Bool ?? true
            if v.isFavourite != want { store.toggleFavourite(projectID: p.id, versionID: v.id) }
            return versionSummary(try version(a).1)
        case "set_version_note":
            let (p, v) = try version(a)
            store.setNote(projectID: p.id, versionID: v.id, note: a["note"] as? String ?? "")
            return versionSummary(try version(a).1)
        case "export": return try export(a)
        case "show_in_app": return try showInApp(a)
        case "render_frame": return try renderFrames(a)
        case "get_app_state": return appState()
        case "apply_overrides": return try applyOverrides(a)
        default: throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Projects

    private func createProject(_ a: [String: Any]) throws -> Any {
        let name = (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled \(store.projects.count + 1)"
        if let geom = try geometryInput(a) {
            let p: AnimationProject
            switch geom {
            case let .svg(data, label):
                let r = try SVGToLottie.convert(svgData: data)
                let svgName = (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? store.uniqueName(SVGToLottie.title(svgData: data) ?? (label == "SVG (MCP)" ? "SVG" : (label as NSString).deletingPathExtension))
                p = store.createProjectFromSVG(name: svgName, svgStaticData: r.data, layerNames: r.layerNames, sourceLabel: label)
                return ["project": try projectDetails(p), "svgWarnings": r.warnings]
            case let .lottie(data, label):
                p = store.createProjectFromLottie(name: name, lottieData: data, sourceLabel: label)
                return ["project": try projectDetails(p)]
            }
        }
        guard store.bundledStaticData() != nil else {
            throw ToolError("No geometry given (svg / svg_path / lottie / lottie_path) and the sample is unavailable. Launch the app once to export it.")
        }
        return ["project": try projectDetails(store.createSampleProject(name: name))]
    }

    private func replaceGeometry(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        guard let geom = try geometryInput(a) else { throw ToolError("Pass svg, svg_path, lottie or lottie_path") }
        switch geom {
        case let .svg(data, label):
            let r = try SVGToLottie.convert(svgData: data)
            store.setImportedStatic(projectID: p.id, data: r.data, layerNames: r.layerNames, sourceLabel: label)
            return ["project": try projectDetails(try project(a)), "svgWarnings": r.warnings]
        case let .lottie(data, label):
            store.setImportedLottie(projectID: p.id, data: data, sourceLabel: label)
            return ["project": try projectDetails(try project(a))]
        }
    }

    private func getGeometry(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        guard let data = store.geometryData(for: p) else { throw ToolError("Geometry unavailable") }
        var out: [String: Any] = [
            "layers": p.layerNames,
            "summary": Self.lottieSummary(data),
            "animations": LottieCompiler.inspectAnimations(lottieData: data) ?? NSNull(),
        ]
        if a["include_lottie"] as? Bool ?? false { out["lottie"] = Self.jsonObject(data) ?? NSNull() }
        return out
    }

    // MARK: - Versions

    private func compileSpec(_ a: [String: Any], save: Bool) throws -> Any {
        let p = try project(a)
        guard let specObj = a["spec"] else { throw ToolError("Missing 'spec' (AnimationSpec object, see get_guide)") }
        let specData: Data
        if let s = specObj as? String { specData = Data(s.utf8) }
        else { specData = try JSONSerialization.data(withJSONObject: specObj) }
        let spec: AnimationSpec
        do { spec = try JSONDecoder().decode(AnimationSpec.self, from: specData) }
        catch { throw ToolError("Invalid AnimationSpec: \(Self.describe(error))") }

        // База: компилируем поверх статичной геометрии или поверх существующей версии.
        var parent: AnimationVersion?
        let base: Data
        if let baseRef = a["base_version"] as? String, !baseRef.isEmpty {
            let v = try findVersion(in: p, baseRef)
            parent = v
            base = try Data(contentsOf: store.versionURL(p.id, v.compiledFile))
        } else {
            guard let g = store.geometryData(for: p) else { throw ToolError("Geometry unavailable") }
            base = g
        }

        let result = try LottieCompiler().compile(staticLottie: base, spec: spec)
        var out: [String: Any] = ["warnings": result.warnings, "summary": Self.lottieSummary(result.data)]
        if !save {
            if a["include_lottie"] as? Bool ?? false { out["lottie"] = Self.jsonObject(result.data) ?? NSNull() }
            return out
        }
        let specJSON = (try? Self.prettyEncoder.encode(spec)).flatMap { String(data: $0, encoding: .utf8) }
        guard let v = store.addVersion(projectID: p.id, prompt: a["prompt"] as? String ?? "",
                                       compiledData: result.data, layerCount: spec.layers.count,
                                       compilerWarnings: result.warnings.count, specJSON: specJSON,
                                       parentVersionID: parent?.id, note: a["note"] as? String ?? "",
                                       source: "mcp") else { throw ToolError("Failed to save version") }
        out["version"] = versionSummary(v)
        if a["show_in_app"] as? Bool ?? true { store.writeUICommand(.init(projectID: p.id, versionID: v.id, issuedAt: Date())) }
        return out
    }

    private func createVersionFromLottie(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        guard case let .lottie(data, _)? = try geometryInput(a) else { throw ToolError("Pass lottie (object/string) or lottie_path") }
        let parent = try (a["base_version"] as? String).flatMap { $0.isEmpty ? nil : try findVersion(in: p, $0) }
        let layers = (Self.jsonObject(data) as? [String: Any])?["layers"] as? [Any] ?? []
        guard let v = store.addVersion(projectID: p.id, prompt: a["prompt"] as? String ?? "", compiledData: data,
                                       layerCount: layers.count, compilerWarnings: 0, specJSON: nil,
                                       parentVersionID: parent?.id, note: a["note"] as? String ?? "",
                                       source: "import") else { throw ToolError("Failed to save version") }
        if a["show_in_app"] as? Bool ?? true { store.writeUICommand(.init(projectID: p.id, versionID: v.id, issuedAt: Date())) }
        return ["version": versionSummary(v), "summary": Self.lottieSummary(data)]
    }

    private func getVersion(_ a: [String: Any]) throws -> Any {
        let (p, v) = try version(a)
        var out = versionSummary(v)
        let data = try Data(contentsOf: store.versionURL(p.id, v.compiledFile))
        out["summary"] = Self.lottieSummary(data)
        out["animations"] = LottieCompiler.inspectAnimations(lottieData: data) ?? NSNull()
        if a["include_spec"] as? Bool ?? true {
            out["spec"] = v.specJSON.flatMap { Self.jsonObject(Data($0.utf8)) } ?? NSNull()
        }
        if a["include_lottie"] as? Bool ?? false { out["lottie"] = Self.jsonObject(data) ?? NSNull() }
        return out
    }

    private func diffVersions(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        let va = try findVersion(in: p, try str(a, "from"))
        let vb = try findVersion(in: p, try str(a, "to"))
        let specA = va.specJSON.flatMap { Self.jsonObject(Data($0.utf8)) }
        let specB = vb.specJSON.flatMap { Self.jsonObject(Data($0.utf8)) }
        var specChanges: [String] = []
        Self.diff(specA ?? NSNull(), specB ?? NSNull(), path: "spec", into: &specChanges)
        let la = try Data(contentsOf: store.versionURL(p.id, va.compiledFile))
        let lb = try Data(contentsOf: store.versionURL(p.id, vb.compiledFile))
        var lottieChanges: [String] = []
        if a["include_lottie_diff"] as? Bool ?? false {
            Self.diff(Self.jsonObject(la) ?? NSNull(), Self.jsonObject(lb) ?? NSNull(), path: "lottie", into: &lottieChanges)
        }
        return [
            "from": versionSummary(va), "to": versionSummary(vb),
            "specChanges": specChanges,
            "summaryFrom": Self.lottieSummary(la), "summaryTo": Self.lottieSummary(lb),
            "lottieChanges": Array(lottieChanges.prefix(500)),
            "lottieChangesTotal": lottieChanges.count,
        ]
    }

    private func restoreVersion(_ a: [String: Any]) throws -> Any {
        let (p, v) = try version(a)
        let data = try Data(contentsOf: store.versionURL(p.id, v.compiledFile))
        guard let nv = store.addVersion(projectID: p.id, prompt: v.prompt, compiledData: data,
                                        layerCount: v.layerCount, compilerWarnings: v.compilerWarnings,
                                        specJSON: v.specJSON, parentVersionID: v.id,
                                        note: a["note"] as? String ?? "Restored from \(v.label)",
                                        source: "restore") else { throw ToolError("Failed to restore") }
        store.writeUICommand(.init(projectID: p.id, versionID: nv.id, issuedAt: Date()))
        return ["version": versionSummary(nv)]
    }

    private func export(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        let path = (try str(a, "path") as NSString).expandingTildeInPath
        let data: Data
        if let ref = a["version"] as? String, !ref.isEmpty {
            data = try Data(contentsOf: store.versionURL(p.id, try findVersion(in: p, ref).compiledFile))
        } else {
            guard let g = store.geometryData(for: p) else { throw ToolError("Geometry unavailable") }
            data = g
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ["written": url.path, "bytes": data.count]
    }

    private func appState() -> Any {
        guard let st = store.readAppState() else { return ["running": false, "note": "No state yet — is the app open?"] }
        let age = Date().timeIntervalSince(st.updatedAt)
        var out: [String: Any] = [
            "projectID": st.projectID?.uuidString ?? NSNull(), "projectName": st.projectName ?? NSNull(),
            "version": st.version ?? NSNull(), "frame": st.frame, "playing": st.playing, "mode": st.mode,
            "engine": st.engine, "activeEngine": st.activeEngine, "selectedLayer": st.selectedLayer ?? NSNull(),
            "updatedAt": Self.iso.string(from: st.updatedAt), "secondsSinceUpdate": Int(age),
        ]
        out["overrides"] = st.overrides.mapValues { o -> [String: Any] in
            ["color": o.color ?? NSNull(), "opacity": o.opacity ?? NSNull(), "hidden": o.hidden]
        }
        return out
    }

    private func applyOverrides(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        guard let raw = a["overrides"] as? [String: Any], !raw.isEmpty else {
            throw ToolError("Missing 'overrides': {\"<layer name>\": {\"color\": \"#FF0000\", \"opacity\": 50, \"hidden\": false}}")
        }
        var overrides: [String: LayerOverride] = [:]
        for (name, v) in raw {
            guard let d = v as? [String: Any] else { continue }
            overrides[name] = LayerOverride(color: d["color"] as? String,
                                            opacity: (d["opacity"] as? NSNumber)?.doubleValue,
                                            hidden: d["hidden"] as? Bool ?? false)
        }
        var parent: AnimationVersion?
        let base: Data
        if let ref = a["version"] as? String, !ref.isEmpty {
            let v = try findVersion(in: p, ref); parent = v
            base = try Data(contentsOf: store.versionURL(p.id, v.compiledFile))
        } else {
            guard let g = store.geometryData(for: p) else { throw ToolError("Geometry unavailable") }
            base = g
        }
        let known = Set(LottieOverrides.layers(in: base).map(\.name))
        let unknown = overrides.keys.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw ToolError("Unknown layers: \(unknown.sorted().joined(separator: ", "))") }
        let data = LottieOverrides.apply(overrides, to: base)
        let note = a["note"] as? String ?? overrides.keys.sorted().joined(separator: ", ")
        guard let v = store.addVersion(projectID: p.id, prompt: a["prompt"] as? String ?? "Overrides on \(parent?.label ?? "geometry")",
                                       compiledData: data, layerCount: parent?.layerCount ?? known.count, compilerWarnings: 0,
                                       specJSON: nil, parentVersionID: parent?.id, note: note, source: "edit")
        else { throw ToolError("Failed to save version") }
        if a["show_in_app"] as? Bool ?? true { store.writeUICommand(.init(projectID: p.id, versionID: v.id, issuedAt: Date())) }
        return ["version": versionSummary(v), "summary": Self.lottieSummary(data)]
    }

    struct RenderedFrames {
        let meta: [String: Any]
        let images: [Data]
    }

    private func renderFrames(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        let data: Data
        var label = "geometry"
        if let ref = a["version"] as? String, !ref.isEmpty {
            let v = try findVersion(in: p, ref)
            label = v.label
            data = try Data(contentsOf: store.versionURL(p.id, v.compiledFile))
        } else {
            guard let g = store.geometryData(for: p) else { throw ToolError("Geometry unavailable") }
            data = g
        }
        let size = (a["size"] as? NSNumber)?.intValue ?? 512
        let bg = FrameRenderer.color(hex: a["background"] as? String)

        // Набор кадров: frames:[...] | count:N (равномерно) | frame | progress.
        var requests: [(frame: Double?, progress: Double?)] = []
        if let list = a["frames"] as? [NSNumber], !list.isEmpty {
            requests = list.prefix(16).map { ($0.doubleValue, nil) }
        } else if let n = (a["count"] as? NSNumber)?.intValue, n > 1 {
            let c = min(n, 16)
            requests = (0..<c).map { (nil, Double($0) / Double(c - 1)) }
        } else {
            requests = [((a["frame"] as? NSNumber)?.doubleValue, (a["progress"] as? NSNumber)?.doubleValue)]
        }

        var images: [Data] = []
        var frames: [[String: Any]] = []
        let savePath = (a["save_dir"] as? String).map { ($0 as NSString).expandingTildeInPath }
        for (i, r) in requests.enumerated() {
            let out = try FrameRenderer.renderPNG(lottieData: data, frame: r.frame, progress: r.progress,
                                                  size: size, background: bg)
            images.append(out.png)
            var info: [String: Any] = ["frame": out.frame, "width": out.width, "height": out.height]
            if let savePath {
                let url = URL(fileURLWithPath: savePath).appendingPathComponent("\(label)_f\(Int(out.frame))_\(i).png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out.png.write(to: url)
                info["saved"] = url.path
            }
            frames.append(info)
        }
        return RenderedFrames(meta: ["project": p.name, "source": label, "frames": frames,
                                     "summary": Self.lottieSummary(data)], images: images)
    }

    private func showInApp(_ a: [String: Any]) throws -> Any {
        let p = try project(a)
        var vid: UUID?
        if let ref = a["version"] as? String, !ref.isEmpty { vid = try findVersion(in: p, ref).id }
        store.writeUICommand(.init(projectID: p.id, versionID: vid, issuedAt: Date(),
                                   frame: (a["frame"] as? NSNumber)?.doubleValue, layer: a["layer"] as? String,
                                   tap: (a["tap"] as? [NSNumber]).map { $0.map(\.doubleValue) }))
        return ["requested": true, "note": "The app opens it within ~1s if it is running."]
    }

    // MARK: - Lookup

    private func project(_ a: [String: Any]) throws -> AnimationProject {
        let ref = try str(a, "project_id")
        if let id = UUID(uuidString: ref), let p = store.project(id) { return p }
        if let p = store.projects.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return p }
        throw ToolError("Project not found: \(ref). Use list_projects.")
    }

    private func version(_ a: [String: Any]) throws -> (AnimationProject, AnimationVersion) {
        let p = try project(a)
        return (p, try findVersion(in: p, try str(a, "version")))
    }

    /// Версия по UUID, метке "v3", числу "3" или "latest".
    private func findVersion(in p: AnimationProject, _ ref: String) throws -> AnimationVersion {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if r == "latest", let v = p.versions.max(by: { $0.index < $1.index }) { return v }
        if let id = UUID(uuidString: ref), let v = p.versions.first(where: { $0.id == id }) { return v }
        let num = Int(r.hasPrefix("v") ? String(r.dropFirst()) : r)
        if let num, let v = p.versions.first(where: { $0.index == num }) { return v }
        throw ToolError("Version not found: \(ref). Use list_versions.")
    }

    private func str(_ a: [String: Any], _ key: String) throws -> String {
        guard let v = a[key] as? String, !v.isEmpty else { throw ToolError("Missing '\(key)'") }
        return v
    }

    private enum GeometryInput { case svg(Data, String), lottie(Data, String) }

    private func geometryInput(_ a: [String: Any]) throws -> GeometryInput? {
        if let s = a["svg"] as? String, !s.isEmpty { return .svg(Data(s.utf8), "SVG (MCP)") }
        if let path = a["svg_path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return .svg(try Data(contentsOf: url), url.lastPathComponent)
        }
        if let l = a["lottie"] {
            let data: Data
            if let str = l as? String { data = Data(str.utf8) } else { data = try JSONSerialization.data(withJSONObject: l) }
            try Self.checkLottie(data)
            return .lottie(data, "Lottie (MCP)")
        }
        if let path = a["lottie_path"] as? String, !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = try Data(contentsOf: url)
            try Self.checkLottie(data)
            return .lottie(data, url.lastPathComponent)
        }
        return nil
    }

    private static func checkLottie(_ data: Data) throws {
        guard let root = jsonObject(data) as? [String: Any], root["layers"] is [Any] else {
            throw ToolError("Not a Lottie JSON (expected an object with 'layers')")
        }
    }

    // MARK: - Serialization

    private func projectSummary(_ p: AnimationProject) -> [String: Any] {
        [
            "id": p.id.uuidString, "name": p.name, "source": p.sourceLabel,
            "layerCount": p.layerNames.count, "versionCount": p.versions.count,
            "latestVersion": p.versions.max(by: { $0.index < $1.index })?.label ?? NSNull(),
            "updatedAt": Self.iso.string(from: p.updatedAt),
        ]
    }

    private func projectDetails(_ p: AnimationProject) throws -> [String: Any] {
        var out = projectSummary(p)
        out["layers"] = p.layerNames
        out["createdAt"] = Self.iso.string(from: p.createdAt)
        out["versions"] = p.versions.sorted { $0.index < $1.index }.map(versionSummary)
        if let g = store.geometryData(for: p) { out["geometrySummary"] = Self.lottieSummary(g) }
        return out
    }

    private func versionSummary(_ v: AnimationVersion) -> [String: Any] {
        [
            "id": v.id.uuidString, "label": v.label, "index": v.index,
            "prompt": v.prompt, "note": v.note, "source": v.source,
            "parentVersionID": v.parentVersionID?.uuidString ?? NSNull(),
            "createdAt": Self.iso.string(from: v.createdAt),
            "layerCount": v.layerCount, "compilerWarnings": v.compilerWarnings,
            "favourite": v.isFavourite, "hasSpec": v.specJSON != nil,
        ]
    }

    static func lottieSummary(_ data: Data) -> [String: Any] {
        guard let root = jsonObject(data) as? [String: Any] else { return [:] }
        let layers = root["layers"] as? [[String: Any]] ?? []
        return [
            "w": root["w"] ?? NSNull(), "h": root["h"] ?? NSNull(),
            "fr": root["fr"] ?? NSNull(), "ip": root["ip"] ?? NSNull(), "op": root["op"] ?? NSNull(),
            "layers": layers.map { ["nm": $0["nm"] ?? NSNull(), "ty": $0["ty"] ?? NSNull()] },
            "bytes": data.count,
        ]
    }

    static func jsonObject(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    static func jsonString(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "\(obj)" }
        return s
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DecodingError {
            switch e {
            case let .keyNotFound(k, c): return "missing key '\(k.stringValue)' at \(path(c))"
            case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c):
                return "\(c.debugDescription) at \(path(c))"
            @unknown default: break
            }
        }
        return error.localizedDescription
    }

    private static func path(_ c: DecodingError.Context) -> String {
        c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }

    /// Рекурсивный дифф двух JSON-значений → строки "path: old → new".
    static func diff(_ a: Any, _ b: Any, path: String, into out: inout [String]) {
        if let da = a as? [String: Any], let db = b as? [String: Any] {
            for k in Set(da.keys).union(db.keys).sorted() {
                diff(da[k] ?? NSNull(), db[k] ?? NSNull(), path: "\(path).\(k)", into: &out)
            }
        } else if let aa = a as? [Any], let ab = b as? [Any] {
            for i in 0..<max(aa.count, ab.count) {
                diff(i < aa.count ? aa[i] : NSNull(), i < ab.count ? ab[i] : NSNull(), path: "\(path)[\(i)]", into: &out)
            }
        } else {
            let sa = short(a), sb = short(b)
            if sa != sb { out.append("\(path): \(sa) → \(sb)") }
        }
    }

    private static func short(_ v: Any) -> String {
        if v is NSNull { return "∅" }
        if JSONSerialization.isValidJSONObject([v]),
           let d = try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            let inner = String(s.dropFirst().dropLast())
            return inner.count > 120 ? String(inner.prefix(117)) + "…" : inner
        }
        return "\(v)"
    }

    private static let iso = ISO8601DateFormatter()
    private static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
