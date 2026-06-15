import SwiftUI

struct ImportSourcePickerView: View {
    let onImportFromFiles: () -> Void
    let onImportFromURL: () -> Void
    let onImportFromClipboard: () -> Void
    let onImportSVGFromFiles: () -> Void
    let onImportSVGFromURL: () -> Void
    let onImportSVGFromClipboard: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Lottie JSON") {
                    Button("Import from Files") {
                        onImportFromFiles()
                    }
                    Button("Import from URL") {
                        onImportFromURL()
                    }
                    Button("Paste from Clipboard") {
                        onImportFromClipboard()
                    }
                }

                Section("SVG (M2)") {
                    Button("Import SVG from Files") {
                        onImportSVGFromFiles()
                    }
                    Button("Import SVG from URL") {
                        onImportSVGFromURL()
                    }
                    Button("Paste SVG from Clipboard") {
                        onImportSVGFromClipboard()
                    }
                }

                Section("Coming Soon") {
                    disabledRow("Prompt/Spec")
                }
            }
            .navigationTitle("Source Picker")
        }
    }

    private func disabledRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(AppTheme.textMuted)
        }
        .accessibilityLabel("\(title) Coming soon")
    }
}
