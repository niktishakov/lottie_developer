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
            "rasterAssets": "Raster flow: create_project(images:[...]) or add_image → get_geometry (imageFrames = layout) → place_layer to arrange → render_frame to check the layout → create_version with an AnimationSpec targeting image layers by name. Image layers support transform motions (fade, slide, scale, rotate, spin, float, bounce, followPath…); shape-only kinds (drawOn, recolor, addFill/Stroke) don't apply.",
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
            tool("create_project", "Create a project from SVG or Lottie geometry, OR a raster project: pass images (file paths; first = top layer, like Figma's layer panel) and/or width+height for a blank composition (size defaults to the first image).",
                 geometryProps.merging([
                    "name": ["type": "string"],
                    "bundle": ["type": "string", "description": "Path to a .zip or folder with SVG / PNG / JPEG / Lottie JSON — all combined into one scene (canvas = largest file, larger files below, SVG/Lottie as groups centered)"],
                    "images": ["type": "array", "items": ["type": "string"], "description": "PNG/JPEG paths, first = top; each becomes an image layer named after the file. Canvas = largest image unless width/height given"],
                    "width": ["type": "integer"], "height": ["type": "integer"],
                    "fps": ["type": "integer", "description": "Default 60"], "frames": ["type": "integer", "description": "Default 120"],
                 ]) { a, _ in a }),
            tool("add_image", "Add a raster image (PNG/JPEG) as a new top image layer to the project's geometry. Optional placement rect in composition coords (top-left + size); default: centered, natural size.",
                 ["project_id": projectID, "path": ["type": "string"], "base64": ["type": "string"],
                  "name": ["type": "string", "description": "Layer name (default: file name)"],
                  "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
                 required: ["project_id"]),
            tool("place_layer", "Arrange the static scene before animating. Image layer: x,y,width,height = exact rect. Group (imported SVG/Lottie) or other layer: x,y = top-left, scale = %. z = 'top' | 'bottom' | index (0 = top).",
                 ["project_id": projectID, "layer": ["type": "string"],
                  "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
                  "scale": ["type": "number"], "z": ["description": "'top', 'bottom' or index"]],
                 required: ["project_id", "layer"]),
            tool("add_svg", "Add an SVG (or Lottie JSON) to the scene as a group named after the file (null layer parenting its parts). Gradients become native; blur/masks become exact image layers. Default: centered.",
                 ["project_id": projectID, "path": ["type": "string"], "svg": ["type": "string", "description": "SVG markup"],
                  "name": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"]],
                 required: ["project_id"]),
            tool("get_feedback", "Designer's comments from the app, each pinned to a version + frame (+ layer). Start every iteration with this. Omit project_id for all projects.",
                 ["project_id": projectID, "status": ["type": "string", "enum": ["open", "resolved", "all"], "description": "Default open"]]),
            tool("resolve_feedback", "Mark a comment resolved (or reopen with resolved=false) and leave a short reply the designer sees in the app. Only after checking the fix with render_frame.",
                 ["project_id": projectID, "id": ["type": "string"], "reply": ["type": "string"], "resolved": ["type": "boolean"]],
                 required: ["project_id", "id"]),
            tool("rename_layer", "Rename a layer (give imported path-1… meaningful names before animating).",
                 ["project_id": projectID, "layer": ["type": "string"], "name": ["type": "string"]],
                 required: ["project_id", "layer", "name"]),
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
            tool("render_frame", "Render frames to PNG so you can SEE the result. Returns images. Use count for a filmstrip.",
                 ["project_id": projectID,
                  "version": ["type": "string", "description": "Version ref; omit for static geometry"],
                  "frame": ["type": "number", "description": "Frame number"],
                  "progress": ["type": "number", "description": "0…1 of the timeline (if no frame)"],
                  "frames": ["type": "array", "items": ["type": "number"], "description": "Several frames (max 16)"],
                  "count": ["type": "integer", "description": "N evenly spaced frames (max 16)"],
                  "size": ["type": "integer", "description": "Max side in px, default 512"],
                  "background": ["type": "string", "description": "Hex like #FFFFFF; default transparent"],
                  "save_dir": ["type": "string", "description": "Optional: also write PNGs here"]],
                 required: ["project_id"]),
            tool("show_in_app", "Open a project in the running app; optionally jump to a version, a frame and select a layer.",
                 ["project_id": projectID, "version": versionRef,
                  "frame": ["type": "number", "description": "Seek to this frame (pauses playback)"],
                  "layer": ["type": "string", "description": "Select and highlight this layer"],
                  "tap": ["type": "array", "items": ["type": "number"],
                          "description": "[x, y] in composition coords: like a click on the canvas (selects the top layer there, or triggers Button/Switch mode)"]],
                 required: ["project_id"]),
            tool("get_app_state", "What the user sees in the app right now: project, version, frame, playing, mode, engine, selected layer, unsaved inspector edits."),
            tool("apply_overrides", "Save a new version with per-layer edits baked in: color (hex, recolors fills/strokes), opacity (0-100 multiplier), hidden.",
                 ["project_id": projectID,
                  "version": ["type": "string", "description": "Base version; omit for static geometry"],
                  "overrides": ["type": "object", "description": "{\"<layer name>\": {\"color\": \"#FF0000\", \"opacity\": 50, \"hidden\": false}}"],
                  "prompt": ["type": "string"], "note": ["type": "string"], "show_in_app": ["type": "boolean"]],
                 required: ["project_id", "overrides"]),
        ]
    }
}
