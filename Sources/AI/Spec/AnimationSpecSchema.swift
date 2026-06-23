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
                "generatedLayers": [
                    "type": "array",
                    "items": generatedLayerSchema,
                    "description": "Layers the compiler creates before animation (waves, halos, particles). Positioned at anchor layer's center."
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
                    "description": "Layer name (nm). Supports trailing wildcard: \"item_*\" matches all layers with that prefix."
                ],
                "animations": [
                    "type": "array",
                    "minItems": 1,
                    "items": primitiveSchema
                ],
                "staggerDelay": [
                    "type": "number",
                    "minimum": 0,
                    "description": "Seconds between each matched layer when target uses wildcard. First layer starts at original time, each next adds staggerDelay."
                ]
            ]
        ]
    }

    private static var generatedLayerSchema: [String: Any] {
        let hexPattern = "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$"
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "shape", "anchor"],
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Unique layer name for targeting in animations."
                ],
                "shape": [
                    "enum": GeneratedShape.allCases.map(\.rawValue),
                    "description": "Shape type: ellipse or rectangle."
                ],
                "anchor": [
                    "type": "string",
                    "description": "Name of existing layer — generated layer copies its position."
                ],
                "width": [
                    "type": "number",
                    "description": "Shape width in px (default 100)."
                ],
                "height": [
                    "type": "number",
                    "description": "Shape height in px (default 100)."
                ],
                "fillColor": [
                    "type": "string",
                    "pattern": hexPattern,
                    "description": "Hex fill color. Omit for stroke-only shapes (rings)."
                ],
                "strokeColor": [
                    "type": "string",
                    "pattern": hexPattern,
                    "description": "Hex stroke color. Omit for filled shapes."
                ],
                "strokeWidth": [
                    "type": "number",
                    "description": "Stroke width in px (default 2)."
                ],
                "opacity": [
                    "type": "number",
                    "minimum": 0,
                    "maximum": 100,
                    "description": "Initial opacity 0–100 (default 0 — animate with fadeIn)."
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
                    "description": "Hex color. recolor: applied instantly. colorTransition: target color."
                ],
                "fromColor": [
                    "type": "string",
                    "pattern": "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$",
                    "description": "Starting hex color for colorTransition. If omitted, reads current fill/stroke."
                ],
                "blurAmount": [
                    "type": "number",
                    "minimum": 0,
                    "description": "Gaussian blur radius for blurIn/blurOut (default 20)."
                ],
                "axis": [
                    "enum": ["x", "y"],
                    "description": "Rotation axis for flip: \"x\" (vertical) or \"y\" (horizontal, default)."
                ]
            ]
        ]
    }
}
