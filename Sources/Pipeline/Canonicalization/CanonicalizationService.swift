import Foundation

struct CanonicalizationSnapshot: Codable {
    let sourceType: SourceType
    let width: Int
    let height: Int
    let sourceName: String
    let metadata: [String: String]
}

struct CanonicalizationService {
    enum CanonicalizationError: LocalizedError {
        case unreadableSource
        case invalidJSON
        case invalidSVG
        case unsupportedSourceType

        var errorDescription: String? {
            switch self {
            case .unreadableSource:
                return "Unable to read source payload"
            case .invalidJSON:
                return "Invalid Lottie JSON source"
            case .invalidSVG:
                return "Invalid SVG source"
            case .unsupportedSourceType:
                return "Source type is not supported"
            }
        }
    }

    private struct SVGMetadata {
        let width: Int
        let height: Int
        let viewBox: String?
    }

    func extractSVGCanvasSize(svgData: Data) throws -> (width: Int, height: Int) {
        let metadata = try parseSVGMetadata(data: svgData)
        return (metadata.width, metadata.height)
    }

    func canonicalize(sourceType: SourceType, sourceURL: URL) throws -> CanonicalizationSnapshot {
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw CanonicalizationError.unreadableSource
        }

        switch sourceType {
        case .lottieJSON:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["v"] != nil,
                  object["w"] != nil,
                  object["h"] != nil,
                  object["layers"] != nil else {
                throw CanonicalizationError.invalidJSON
            }

            let width = clampSize(parseNumber(object["w"]) ?? 512)
            let height = clampSize(parseNumber(object["h"]) ?? 512)
            return CanonicalizationSnapshot(
                sourceType: .lottieJSON,
                width: width,
                height: height,
                sourceName: sourceURL.lastPathComponent,
                metadata: ["format": "lottie_json"]
            )

        case .svg:
            let svg = try parseSVGMetadata(data: data)
            return CanonicalizationSnapshot(
                sourceType: .svg,
                width: svg.width,
                height: svg.height,
                sourceName: sourceURL.lastPathComponent,
                metadata: [
                    "format": "svg",
                    "viewbox": svg.viewBox ?? ""
                ]
            )

        case .promptSpec:
            throw CanonicalizationError.unsupportedSourceType
        }
    }

    func generateDraftJSON(
        sourceType: SourceType,
        sourceURL: URL,
        canonical: CanonicalizationSnapshot,
        runDirectory: URL
    ) throws -> URL {
        let draftData: Data

        switch sourceType {
        case .lottieJSON:
            guard let data = try? Data(contentsOf: sourceURL),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw CanonicalizationError.invalidJSON
            }
            draftData = data

        case .svg:
            guard let svgData = try? Data(contentsOf: sourceURL) else {
                throw CanonicalizationError.unreadableSource
            }
            draftData = try makeDraftDataFromSVG(
                svgData: svgData,
                sourceName: canonical.sourceName,
                preferredWidth: canonical.width,
                preferredHeight: canonical.height
            )

        case .promptSpec:
            throw CanonicalizationError.unsupportedSourceType
        }

        let outputURL = runDirectory.appendingPathComponent("draft-\(UUID().uuidString).json")
        try draftData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    func makeDraftDataFromSVG(svgData: Data, sourceName: String) throws -> Data {
        try makeDraftDataFromSVG(
            svgData: svgData,
            sourceName: sourceName,
            preferredWidth: nil,
            preferredHeight: nil
        )
    }

    func makeDraftDataFromPNG(
        pngData: Data,
        sourceName: String,
        width: Int,
        height: Int
    ) throws -> Data {
        let safeWidth = clampSize(width)
        let safeHeight = clampSize(height)
        let base64 = pngData.base64EncodedString()

        let object: [String: Any] = [
            "v": "5.9.0",
            "fr": 60,
            "ip": 0,
            "op": 60,
            "w": safeWidth,
            "h": safeHeight,
            "nm": "SVG Draft: \(sourceName)",
            "ddd": 0,
            "assets": [
                [
                    "id": "image_0",
                    "w": safeWidth,
                    "h": safeHeight,
                    "u": "",
                    "p": "data:image/png;base64,\(base64)",
                    "e": 1
                ]
            ],
            "layers": [
                [
                    "ddd": 0,
                    "ind": 1,
                    "ty": 2,
                    "nm": "SVG Rasterized Layer",
                    "refId": "image_0",
                    "sr": 1,
                    "ks": [
                        "o": ["a": 0, "k": 100],
                        "r": ["a": 0, "k": 0],
                        "p": ["a": 0, "k": [Double(safeWidth) / 2.0, Double(safeHeight) / 2.0, 0]],
                        "a": ["a": 0, "k": [Double(safeWidth) / 2.0, Double(safeHeight) / 2.0, 0]],
                        "s": ["a": 0, "k": [100, 100, 100]]
                    ],
                    "ao": 0,
                    "ip": 0,
                    "op": 60,
                    "st": 0,
                    "bm": 0
                ]
            ],
            "meta": [
                "generator": "svg_m2_rasterizer"
            ]
        ]

        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }

    private func makeDraftDataFromSVG(
        svgData: Data,
        sourceName: String,
        preferredWidth: Int?,
        preferredHeight: Int?
    ) throws -> Data {
        let parsed = try parseSVGMetadata(data: svgData)
        let width = clampSize(preferredWidth ?? parsed.width)
        let height = clampSize(preferredHeight ?? parsed.height)
        return try makeTemplateDraftData(width: width, height: height, sourceName: sourceName)
    }

    private func makeTemplateDraftData(width: Int, height: Int, sourceName: String) throws -> Data {
        let object: [String: Any] = [
            "v": "5.9.0",
            "fr": 60,
            "ip": 0,
            "op": 60,
            "w": width,
            "h": height,
            "nm": "SVG Draft: \(sourceName)",
            "ddd": 0,
            "assets": [],
            "layers": [
                [
                    "ddd": 0,
                    "ind": 1,
                    "ty": 4,
                    "nm": "Converted SVG Layer",
                    "sr": 1,
                    "ks": [
                        "o": ["a": 0, "k": 100],
                        "r": ["a": 0, "k": 0],
                        "p": ["a": 0, "k": [Double(width) / 2.0, Double(height) / 2.0, 0]],
                        "a": ["a": 0, "k": [0, 0, 0]],
                        "s": ["a": 0, "k": [100, 100, 100]]
                    ],
                    "shapes": [
                        [
                            "ty": "rc",
                            "d": 1,
                            "s": ["a": 0, "k": [width, height]],
                            "p": ["a": 0, "k": [0, 0]],
                            "r": ["a": 0, "k": 0],
                            "nm": "Rect Path"
                        ],
                        [
                            "ty": "fl",
                            "c": ["a": 0, "k": [0.1, 0.6, 0.9, 1]],
                            "o": ["a": 0, "k": 100],
                            "r": 1,
                            "nm": "Fill"
                        ],
                        [
                            "ty": "tr",
                            "p": ["a": 0, "k": [0, 0]],
                            "a": ["a": 0, "k": [0, 0]],
                            "s": ["a": 0, "k": [100, 100]],
                            "r": ["a": 0, "k": 0],
                            "o": ["a": 0, "k": 100],
                            "nm": "Transform"
                        ]
                    ],
                    "ao": 0,
                    "ip": 0,
                    "op": 60,
                    "st": 0,
                    "bm": 0
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }

    private func parseSVGMetadata(data: Data) throws -> SVGMetadata {
        guard let svg = String(data: data, encoding: .utf8),
              svg.range(of: "<svg", options: .caseInsensitive) != nil else {
            throw CanonicalizationError.invalidSVG
        }

        let widthAttr = extractAttribute("width", in: svg)
        let heightAttr = extractAttribute("height", in: svg)
        let viewBox = extractAttribute("viewBox", in: svg)

        var width = parseLength(widthAttr)
        var height = parseLength(heightAttr)

        if (width == nil || height == nil), let viewBox {
            let parts = viewBox
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0.isWhitespace })

            if parts.count >= 4 {
                let viewBoxWidth = Int((Double(parts[2]) ?? 0).rounded())
                let viewBoxHeight = Int((Double(parts[3]) ?? 0).rounded())
                if width == nil, viewBoxWidth > 0 {
                    width = viewBoxWidth
                }
                if height == nil, viewBoxHeight > 0 {
                    height = viewBoxHeight
                }
            }
        }

        return SVGMetadata(
            width: clampSize(width ?? 512),
            height: clampSize(height ?? 512),
            viewBox: viewBox
        )
    }

    private func extractAttribute(_ name: String, in input: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)\\b\(escapedName)\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, options: [], range: range) else {
            return nil
        }

        for index in [1, 2] {
            let nsRange = match.range(at: index)
            if nsRange.location != NSNotFound,
               let range = Range(nsRange, in: input) {
                return String(input[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private func parseLength(_ value: String?) -> Int? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasSuffix("%") else { return nil }

        guard let regex = try? NSRegularExpression(pattern: "[-+]?[0-9]*\\.?[0-9]+"),
              let match = regex.firstMatch(
                in: value,
                options: [],
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 0), in: value),
              let number = Double(value[range]) else {
            return nil
        }

        let rounded = Int(number.rounded())
        return rounded > 0 ? rounded : nil
    }

    private func parseNumber(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value.rounded())
        }
        if let value = value as? NSNumber {
            return Int(value.doubleValue.rounded())
        }
        return nil
    }

    private func clampSize(_ value: Int) -> Int {
        min(max(value, 1), 4096)
    }
}
