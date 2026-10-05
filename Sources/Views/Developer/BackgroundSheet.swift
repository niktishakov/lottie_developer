#if os(iOS)
import SwiftUI
import Inject
import UIKit

/// Выбор фона под анимацией: клетка, светлый, тёмный или свой цвет.
/// Для сплошного фона показывает контраст с основными цветами анимации (WCAG): видно, что потеряется на этом фоне.
struct BackgroundSheet: View {
    @ObserveInjection private var inject
    @Binding var kind: DevBackground
    @Binding var customHex: String
    let lottieURL: URL?
    @Environment(\.dismiss) private var dismiss

    private static let presets = ["#FFFFFF", "#F2F2F7", "#BFE3FF", "#FFD166", "#FF453A", "#1C1C1E", "#000000"]

    private var customColor: Binding<Color> {
        Binding(get: { Color(hex: customHex) ?? .white },
                set: { customHex = $0.hex; kind = .custom })
    }

    var body: some View {
        content.enableInjection()
    }

    @ViewBuilder private var content: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Background", selection: $kind) {
                        ForEach(DevBackground.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    ColorPicker("Your color", selection: customColor, supportsOpacity: false)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // Мозаика — первым кружком: прозрачные места анимации видны сразу.
                            Button { kind = .checker } label: {
                                DevBackgroundView(kind: .checker).frame(width: 34, height: 34).clipShape(Circle())
                                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                                    .overlay(Circle().strokeBorder(.tint, lineWidth: kind == .checker ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            ForEach(Self.presets, id: \.self) { hex in
                                Button { customHex = hex; kind = .custom } label: {
                                    Circle().fill(Color(hex: hex) ?? .clear).frame(width: 34, height: 34)
                                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                                        .overlay(Circle().strokeBorder(.tint, lineWidth: kind == .custom && customHex == hex ? 3 : 0))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                contrastSection
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Контраст

    /// Сплошной цвет фона; у клетки контраст не считаем.
    private var solidBackground: UIColor? {
        switch kind {
        case .checker: nil
        case .light: .white
        case .dark: UIColor(white: 0.08, alpha: 1)
        case .custom: UIColor(Color(hex: customHex) ?? .white)
        }
    }

    @ViewBuilder private var contrastSection: some View {
        let colors = lottieURL.map { LottieColors.main(in: $0) } ?? []
        Section {
            if let bg = solidBackground {
                if colors.isEmpty {
                    Text("No solid colors found in this animation.").foregroundStyle(.secondary)
                }
                ForEach(colors, id: \.hex) { c in
                    let ratio = Contrast.ratio(c.color, bg)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: c.color)).frame(width: 28, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.layer).lineLimit(1)
                            Text(c.hex).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f:1", ratio)).monospacedDigit()
                        ContrastBadge(ratio: ratio)
                    }
                }
            } else {
                Text("Mosaic shows transparent areas. Pick a solid background to check contrast.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Contrast with the background")
        } footer: {
            Text("3:1 is the minimum for shapes and large text to stay visible, 4.5:1 for small text (WCAG).")
        }
    }
}

private struct ContrastBadge: View {
    let ratio: Double
    var body: some View {
        let (text, color): (String, Color) = ratio >= 4.5 ? ("Good", .green) : (ratio >= 3 ? ("OK", .orange) : ("Low", .red))
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .frame(width: 52)
    }
}

// MARK: - Цвета анимации

/// Основные сплошные цвета Lottie: статичные заливки и обводки фигур, по площади не считаем — по числу использований.
enum LottieColors {
    struct Item { let color: UIColor; let hex: String; let layer: String }

    static func main(in url: URL, limit: Int = 6) -> [Item] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var counts: [String: (Int, String, UIColor)] = [:]
        func walk(_ v: Any, layer: String) {
            if let d = v as? [String: Any] {
                // Слой → «plane», группа внутри → «plane · stripe».
                var name = layer
                if (d["ty"] as? Int) != nil, d["shapes"] != nil, let nm = d["nm"] as? String { name = nm }
                if d["ty"] as? String == "gr", let nm = d["nm"] as? String, !nm.isEmpty {
                    name = layer.isEmpty ? nm : "\(layer.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? layer) · \(nm)"
                }
                if let ty = d["ty"] as? String, ty == "fl" || ty == "st",
                   let c = d["c"] as? [String: Any], (c["a"] as? Int ?? 0) == 0,
                   let k = c["k"] as? [Any], k.count >= 3 {
                    let rgb = k.prefix(3).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                    let color = UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
                    let hex = Color(uiColor: color).hex
                    let old = counts[hex]
                    counts[hex] = ((old?.0 ?? 0) + 1, old?.1 ?? name, color)
                }
                for (_, x) in d { walk(x, layer: name) }
            } else if let a = v as? [Any] {
                for x in a { walk(x, layer: layer) }
            }
        }
        walk(root["layers"] ?? [], layer: "")
        for asset in root["assets"] as? [[String: Any]] ?? [] { walk(asset["layers"] ?? [], layer: "") }
        return counts.sorted { $0.value.0 > $1.value.0 }.prefix(limit)
            .map { Item(color: $0.value.2, hex: $0.key, layer: $0.value.1.isEmpty ? "Shape" : $0.value.1) }
    }
}

/// Контраст двух цветов по WCAG 2.x.
enum Contrast {
    static func ratio(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" в sRGB.
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}
#endif
