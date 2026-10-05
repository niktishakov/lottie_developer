#if os(iOS)
import Foundation
import ZIPFoundation

/// Готовый Lottie от дизайнера (.json или .lottie) → новый проект с версией v1, чтобы посмотреть на настоящем lottie-ios.
@MainActor
enum LottieImport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func importFile(_ url: URL, into store: ProjectStore) throws -> AnimationProject {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure(message: "Can't read \(url.lastPathComponent).") }
        let json = url.pathExtension.lowercased() == "lottie" ? try dotLottieAnimation(data) : data
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["layers"] is [Any], obj["op"] != nil
        else { throw Failure(message: "\(url.lastPathComponent) isn't a Lottie animation.") }

        let name = store.uniqueName(url.deletingPathExtension().lastPathComponent)
        let project = store.createProjectFromLottie(name: name, lottieData: json, sourceLabel: url.lastPathComponent)
        let layers = (obj["layers"] as? [Any])?.count ?? 0
        store.addVersion(projectID: project.id, prompt: "", compiledData: json, layerCount: layers,
                         compilerWarnings: 0, specJSON: nil, note: "Imported \(url.lastPathComponent)", source: "file")
        return store.project(project.id) ?? project
    }

    /// .lottie — zip: берём первую анимацию, картинки из images/ вшиваем в JSON (data URI), чтобы файл был самодостаточным.
    private static func dotLottieAnimation(_ data: Data) throws -> Data {
        guard let archive = try? Archive(data: data, accessMode: .read) else { throw Failure(message: "The .lottie file is damaged.") }
        func read(_ entry: Entry) -> Data? {
            var out = Data()
            _ = try? archive.extract(entry) { out.append($0) }
            return out
        }
        guard let animEntry = archive.first(where: { $0.path.hasPrefix("animations/") && $0.path.hasSuffix(".json") }),
              let animData = read(animEntry),
              var anim = try? JSONSerialization.jsonObject(with: animData) as? [String: Any]
        else { throw Failure(message: "No animation inside the .lottie file.") }
        if var assets = anim["assets"] as? [[String: Any]] {
            for i in assets.indices {
                guard let p = assets[i]["p"] as? String, !p.hasPrefix("data:"),
                      let entry = archive.first(where: { $0.path.hasSuffix("images/\(p)") }),
                      let img = read(entry) else { continue }
                let mime = p.lowercased().hasSuffix(".png") ? "image/png" : (p.lowercased().hasSuffix(".webp") ? "image/webp" : "image/jpeg")
                assets[i]["p"] = "data:\(mime);base64,\(img.base64EncodedString())"
                assets[i]["u"] = ""
                assets[i]["e"] = 1
            }
            anim["assets"] = assets
        }
        return try JSONSerialization.data(withJSONObject: anim)
    }
}
#endif
