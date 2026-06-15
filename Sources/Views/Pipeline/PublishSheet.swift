import SwiftUI

struct PublishSheet: View {
    let ready: ReadyLottie?
    let onPublish: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publish / Handoff")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.textPrimary)

                if let ready {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Artifact: \(ready.artifactRef)")
                        Text("Manifest: \(ready.releaseManifestRef)")
                        Text("Checksum: \(ready.checksum)")
                            .font(.caption.monospaced())
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text("No published artifact yet")
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Button("Publish") {
                    onPublish()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Publish")

                Spacer()
            }
            .padding(20)
            .background(AppBackground().ignoresSafeArea())
        }
    }
}
