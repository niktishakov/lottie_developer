import SwiftUI

enum AppTheme {
    static let backgroundStart = Color(red: 0.04, green: 0.12, blue: 0.22)
    static let backgroundEnd = Color(red: 0.02, green: 0.08, blue: 0.16)

    static let surface = Color.white.opacity(0.08)
    static let surfaceEmphasis = Color.white.opacity(0.12)
    static let border = Color.white.opacity(0.16)
    static let borderSoft = Color.white.opacity(0.1)

    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.7)
    static let textMuted = Color.white.opacity(0.54)

    static let accentStart = Color.cyan
    static let accentEnd = Color.blue

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentStart, accentEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundStart, backgroundEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct AppBackground: View {
    var body: some View {
        AppTheme.backgroundGradient
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(AppTheme.accentStart.opacity(0.16))
                    .frame(width: 320, height: 320)
                    .blur(radius: 60)
                    .offset(x: -44, y: -120)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(AppTheme.accentEnd.opacity(0.12))
                    .frame(width: 320, height: 320)
                    .blur(radius: 70)
                    .offset(x: 72, y: 100)
            }
    }
}

extension View {
    func appGlassCard(
        cornerRadius: CGFloat = 18,
        fillOpacity: Double = 0.08,
        borderOpacity: Double = 0.14
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(fillOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(borderOpacity), lineWidth: 1)
                )
        )
    }
}

struct CheckerboardBackground: View {
    let squareSize: CGFloat = 10
    var color: Color = .white.opacity(0.22)

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    guard (row + col).isMultiple(of: 2) else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
