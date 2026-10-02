import Foundation

/// Описания инструментов (tools/list) и гайд для агента.
extension MCPServer {

    static let instructions = """
    Lottie Developer: you drive animation development from outside. Workflow: get_guide → list_projects / \
    create_project (from SVG or Lottie) → get_project (layer names) → validate_spec → create_version → \
    get_version / diff_versions → iterate (base_version to build on top of a version) → restore_version / export. \
    Every version is kept in history; the running app shows changes live.
    """

    func guide() -> [String: Any] {
        let schema = AnimationSpecSchema.inputSchema
        return [
            "overview": """
            You don't write raw Lottie by default. You write an AnimationSpec (JSON, schema below) that says HOW to \
            animate existing layers; a deterministic compiler turns it into Lottie. Layers are referenced by EXACT name \
            (see get_project.layers). For full manual control you can also save raw Lottie with create_version_from_lottie.
            """,
            "rules": [
                "fps MUST be 60; durationFrames 1..600 (= seconds × 60); start/end are in SECONDS.",
                "kind ∈ " + MotionKind.allCases.map(\.rawValue).joined(separator: ", "),
                "easing ∈ " + Easing.allCases.map(\.rawValue).joined(separator: ", "),
                "Loops: spin (360°), float (vertical hover), breathe (subtle scale), swing (pendulum).",
                "followPath: params.path = [[dx,dy], ...] offsets from base position, min 2 points.",
                "recolor: params.color hex (\"#FF0000\"); applied at start, end ignored.",
                "Shape edits (removeFill, removeStroke, addStroke{color,strokeWidth}, addFill{color}, hideLayer, showLayer) are INSTANT: use start=0, end=0, easing=linear.",
                "generatedLayers: new ellipse/rectangle layers anchored to existing ones (rings, waves, halos, particles).",
                "Modify mode: pass base_version — only channels you animate are overwritten, the rest stays.",
            ],
            "motionTips": [
                "Stagger entrances by 0.05–0.15s; don't start everything at t=0.",
                "Entrances: easeOut or easeOutBack. Settles: spring / easeOutBack. Anticipation: anticipate / easeInBack.",
                "Add idle loops only when asked. One or two subtle accents beat many.",
            ],
            "versionRefs": "Versions are referenced by UUID, label \"v3\", number \"3\" or \"latest\". Projects by UUID or exact name.",
            "schema": schema,
        ]
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    private static let projectID: [String: Any] = ["type": "string", "description": "Project UUID or exact name"]
    private static let versionRef: [String: Any] = ["type": "string", "description": "Version UUID, \"v3\", \"3\" or \"latest\""]
    private static let geometryProps: [String: Any] = [
        "svg": ["type": "string", "description": "SVG markup"],
        "svg_path": ["type": "string", "description": "Path to .svg file"],
        "lottie": ["description": "Lottie JSON (object or string)"],
        "lottie_path": ["type": "string", "description": "Path to Lottie .json file"],
    ]

    static var tools: [[String: Any]] {
        let specProps: [String: Any] = [
            "project_id": projectID,
            "spec": ["type": "object", "description": "AnimationSpec (see get_guide.schema)"],
            "base_version": ["type": "string", "description": "Optional: compile on top of this version instead of static geometry"],
        ]
        return [
            tool("get_guide", "Rules, motion tips and the full AnimationSpec JSON schema. Call first."),
            tool("list_projects", "All projects with version counts."),
            tool("get_project", "Project details: layer names, geometry summary, full version history.",
                 ["project_id": projectID], required: ["project_id"]),
            tool("create_project", "Create a project from SVG or Lottie geometry (or the bundled sample if none given).",
                 geometryProps.merging(["name": ["type": "string"]]) { a, _ in a }),
            tool("rename_project", "Rename a project.", ["project_id": projectID, "name": ["type": "string"]],
                 required: ["project_id", "name"]),
            tool("delete_project", "Delete a project and all its versions. Irreversible.",
                 ["project_id": projectID], required: ["project_id"]),
            tool("replace_geometry", "Replace the project's static geometry (SVG or Lottie). Existing versions are kept.",
                 geometryProps.merging(["project_id": projectID]) { a, _ in a }, required: ["project_id"]),
            tool("get_geometry", "Static geometry: layers, summary, existing animations; optional raw Lottie.",
                 ["project_id": projectID, "include_lottie": ["type": "boolean"]], required: ["project_id"]),
            tool("validate_spec", "Compile an AnimationSpec without saving. Returns compiler warnings (and Lottie if include_lottie).",
                 specProps.merging(["include_lottie": ["type": "boolean"]]) { a, _ in a }, required: ["project_id", "spec"]),
            tool("create_version", "Compile an AnimationSpec and save it as a new version (shown in the app).",
                 specProps.merging([
                    "prompt": ["type": "string", "description": "What this version is meant to do"],
                    "note": ["type": "string"],
                    "show_in_app": ["type": "boolean", "description": "Default true"],
                 ]) { a, _ in a }, required: ["project_id", "spec"]),
            tool("create_version_from_lottie", "Save a raw, hand-made Lottie JSON as a new version (full manual control).",
                 ["project_id": projectID, "lottie": ["description": "Lottie JSON object or string"],
                  "lottie_path": ["type": "string"], "base_version": ["type": "string", "description": "Parent version (history only)"],
                  "prompt": ["type": "string"], "note": ["type": "string"], "show_in_app": ["type": "boolean"]],
                 required: ["project_id"]),
            tool("list_versions", "Version history in order, with parent links, notes, favourites.",
                 ["project_id": projectID], required: ["project_id"]),
            tool("get_version", "One version: metadata, spec, animation summary; optional raw Lottie.",
                 ["project_id": projectID, "version": versionRef, "include_spec": ["type": "boolean"],
                  "include_lottie": ["type": "boolean"]], required: ["project_id", "version"]),
            tool("diff_versions", "Diff two versions: spec changes (path: old → new), summaries, optional raw Lottie diff.",
                 ["project_id": projectID, "from": versionRef, "to": versionRef,
                  "include_lottie_diff": ["type": "boolean"]], required: ["project_id", "from", "to"]),
            tool("restore_version", "Roll back: copy an old version as a new latest version.",
                 ["project_id": projectID, "version": versionRef, "note": ["type": "string"]],
                 required: ["project_id", "version"]),
            tool("delete_version", "Delete a version. Irreversible.",
                 ["project_id": projectID, "version": versionRef], required: ["project_id", "version"]),
            tool("set_favourite", "Mark/unmark a version as favourite.",
                 ["project_id": projectID, "version": versionRef, "favourite": ["type": "boolean"]],
                 required: ["project_id", "version"]),
            tool("set_version_note", "Set a note on a version.",
                 ["project_id": projectID, "version": versionRef, "note": ["type": "string"]],
                 required: ["project_id", "version", "note"]),
            tool("export", "Write a version's Lottie (or the static geometry if no version) to a file path.",
                 ["project_id": projectID, "version": versionRef, "path": ["type": "string"]],
                 required: ["project_id", "path"]),
            tool("show_in_app", "Open a project (and optionally a version) in the running Lottie Developer app.",
                 ["project_id": projectID, "version": versionRef], required: ["project_id"]),
        ]
    }
}
