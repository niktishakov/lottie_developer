#if os(macOS)
import Foundation

/// Построение system/user промптов (API-контракт для claude/codex) и парсинг AnimationSpec.
enum CLIPrompts {

    /// JSON Schema контракта (та же, что для structured output) — встраивается в system prompt.
    static func schemaJSON() -> String {
        if let data = try? JSONSerialization.data(withJSONObject: AnimationSpecSchema.inputSchema,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    static func systemPrompt(layerNames: [String], animationContext: String? = nil) -> String {
        let names = layerNames.map { "\"\($0)\"" }.joined(separator: ", ")

        let modeBlock: String
        if let ctx = animationContext {
            modeBlock = """

            MODE: FIX / MODIFY an existing animated Lottie.
            Current animation state of the source:
            \(ctx)

            The user describes what to change. Re-animate ONLY the layers/channels mentioned in the request — \
            the compiler will overwrite those channels. All other layers/channels remain untouched. \
            Match the existing fps and duration unless the user asks to change them.
            If a layer needs new shapes that don't exist (waves, halos, particles), use generatedLayers.
            """
        } else {
            modeBlock = """

            MODE: CREATE new animation from a static Lottie.
            """
        }

        return """
        You are a senior motion designer. You produce an AnimationSpec that describes HOW to animate \
        the layers of an existing Lottie. You DO NOT write Lottie/bodymovin JSON — a deterministic \
        compiler turns your AnimationSpec into Lottie.

        Output ONLY a single JSON object that conforms to this schema (no markdown, no code fences, no prose):
        \(schemaJSON())
        \(modeBlock)

        Hard rules:
        - fps MUST be 60.
        - durationFrames must be 1..600 (= seconds × 60).
        - start/end are in SECONDS.
        - kind ∈ fadeIn, fadeOut, slideIn, slideOut, scaleIn, scaleOut, rotate, pulse, bounce, drawOn, wiggle,
          spin (continuous 360° loop), float (gentle vertical hover loop), breathe (subtle scale loop), swing (pendulum rotation loop),
          followPath (move layer along a path defined by params.path: [[dx,dy], ...] offsets from base position, min 2 points),
          recolor (instantly change all fill/stroke colors of the layer to params.color, a hex string like "#FF0000" or "#FFF"; applied at start time, end is ignored),
          squash, stretch, flash, flip, colorTransition, blurIn, blurOut,
          removeFill (strip all fills), removeStroke (strip all strokes), addStroke (params.color, params.strokeWidth), \
          addFill (params.color), hideLayer (opacity→0), showLayer (opacity→100).
        - Shape-edit kinds (removeFill, removeStroke, addStroke, addFill, hideLayer, showLayer) are INSTANT — \
          start/end/easing are required by schema but ignored. Use start=0, end=0, easing=linear.
        - easing ∈ linear, easeIn, easeOut, easeInOut, spring, easeOutBack (overshoot), easeInBack, easeInOutBack, anticipate, elastic.
        - generatedLayers: create new shape layers (ellipse, rectangle) anchored to existing layers. \
          Use for effects like rings, waves, halos, particles that don't exist in the source.
        - Animate ONLY these existing layers, by their EXACT names: \(names).

        Motion-design guidance (for a beautiful 60fps result):
        - Stagger entrances by 0.05–0.15s across layers; don't start everything at t=0.
        - Entrances: prefer easeOut or easeOutBack (a little overshoot reads as lively, not stiff).
        - Settles: spring or easeOutBack. Anticipation (anticipate/easeInBack) before a strong move adds energy.
        - ONLY add idle loops (float, breathe, swing, spin) if the user explicitly asks for them or says "stay alive" / "idle loop".
          Do NOT add extra animations beyond what was requested.
        - Keep accents subtle; don't overlap many loud loops. One or two tasteful accents beat many.

        Output ONLY the JSON object.
        """
    }

    static func userPrompt(request: String, layerNames: [String], durationSeconds: Double, repairNote: String) -> String {
        var text = """
        Create a 60fps animation of about \(Int(durationSeconds.rounded())) seconds for this request:

        \(request)

        Available layers (use exact names): \(layerNames.joined(separator: ", "))
        """
        if !repairNote.isEmpty {
            text += "\n\n\(repairNote)"
        }
        return text
    }

    /// Извлекает JSON-объект из ответа модели (срезает code fences и обрамляющий текст).
    static func extractJSONObject(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    static func decodeSpec(from text: String) throws -> AnimationSpec {
        let json = extractJSONObject(from: text)
        guard let data = json.data(using: .utf8) else {
            throw CLIProviderError.invalidSpec("Output is not valid UTF-8")
        }
        return try JSONDecoder().decode(AnimationSpec.self, from: data)
    }
}
#endif
