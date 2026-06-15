import Foundation

/// JSON Schema для `AnimationSpec`, которую мы передаём LLM как `input_schema` инструмента
/// (Anthropic tool use / structured output). Схема намеренно маленькая — вся сложность Lottie
/// живёт в детерминированном `LottieCompiler`, а не в выводе модели.
enum AnimationSpecSchema {
    /// Имя инструмента, который форсируется через `tool_choice`.
    static let toolName = "emit_animation_spec"

    static let toolDescription = """
    Emit an animation specification describing how to animate the named layers of an existing \
    static Lottie. Only reference layers by their exact `nm`. Use seconds for start/end. Do not \
    output Lottie JSON — only this spec.
    """

    /// JSON Schema (draft 2020-12 compatible subset) как готовый объект для сериализации в тело запроса.
    static var inputSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["fps", "durationFrames", "layers"],
            "properties": [
                "fps": [
                    "type": "integer",
                    "minimum": AnimationSpec.minFPS,
                    "maximum": AnimationSpec.maxFPS,
                    "description": "Composition frame rate."
                ],
                "durationFrames": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": AnimationSpec.maxDurationFrames,
                    "description": "Composition length in frames."
                ],
                "layers": [
                    "type": "array",
                    "minItems": 1,
                    "items": layerSchema
                ]
            ]
        ]
    }

    private static var layerSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["target", "animations"],
            "properties": [
                "target": [
                    "type": "string",
                    "description": "Exact layer name (nm) from the static Lottie."
                ],
                "animations": [
                    "type": "array",
                    "minItems": 1,
                    "items": primitiveSchema
                ]
            ]
        ]
    }

    private static var primitiveSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "start", "end", "easing"],
            "properties": [
                "kind": ["enum": MotionKind.allCases.map(\.rawValue)],
                "start": ["type": "number", "minimum": 0],
                "end": ["type": "number", "minimum": 0],
                "easing": ["enum": Easing.allCases.map(\.rawValue)],
                "params": paramsSchema
            ]
        ]
    }

    private static var paramsSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "direction": ["enum": ["up", "down", "left", "right"]],
                "distance": ["type": "number"],
                "from": ["type": "number"],
                "to": ["type": "number"],
                "fromDeg": ["type": "number"],
                "toDeg": ["type": "number"],
                "amount": ["type": "number"],
                "frequency": ["type": "number"],
                "repeatCount": ["type": "integer", "minimum": 1],
                "path": [
                    "type": "array",
                    "minItems": 2,
                    "items": [
                        "type": "array",
                        "minItems": 2,
                        "maxItems": 2,
                        "items": ["type": "number"]
                    ],
                    "description": "Control points [[dx,dy], ...] for followPath. Offsets from layer base position."
                ],
                "color": [
                    "type": "string",
                    "pattern": "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$",
                    "description": "Hex color for recolor kind, e.g. \"#FFFFFF\" or \"#FFF\". Applied instantly at start time."
                ]
            ]
        ]
    }
}
