#if os(macOS)
import Foundation

/// Модели, доступные для генерации через `claude --model`.
/// id — алиас/имя, передаваемое CLI (алиас всегда указывает на последнюю версию тира).
struct AIModel: Identifiable, Hashable {
    let id: String
    let label: String
    let blurb: String
    let supportsFastMode: Bool

    static let all: [AIModel] = [
        AIModel(id: "claude-opus-4-8",            label: "Opus 4.8",   blurb: "Most capable",  supportsFastMode: true),
        AIModel(id: "claude-opus-4-6",            label: "Opus 4.6",   blurb: "Capable",        supportsFastMode: true),
        AIModel(id: "claude-sonnet-4-6",          label: "Sonnet 4.6", blurb: "Balanced",       supportsFastMode: false),
        AIModel(id: "claude-haiku-4-5-20251001",  label: "Haiku 4.5",  blurb: "Fastest",        supportsFastMode: false),
    ]

    static let defaultID = "claude-opus-4-8"

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id.capitalized
    }

    static func supportsFastMode(for id: String) -> Bool {
        all.first { $0.id == id }?.supportsFastMode ?? false
    }
}

/// Уровень reasoning effort для `claude --effort`. Пустой id → флаг не передаём (дефолт CLI).
struct AIEffort: Identifiable, Hashable {
    let id: String
    let label: String

    static let all: [AIEffort] = [
        AIEffort(id: "",       label: "Default effort"),
        AIEffort(id: "low",    label: "Low"),
        AIEffort(id: "medium", label: "Medium"),
        AIEffort(id: "high",   label: "High"),
        AIEffort(id: "xhigh",  label: "Extra high"),
        AIEffort(id: "max",    label: "Max"),
    ]

    static let defaultID = ""

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? (id.isEmpty ? "Default effort" : id.capitalized)
    }
}
#endif
