import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AnimationLibraryView: View {
    @Environment(AnimationStore.self) private var store
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var showPasteImporter = false
    @State private var pasteName = ""
    @State private var urlString = ""
    @State private var searchText = ""
    @State private var importError: String?
    @State private var showError = false
    @State private var isDownloading = false

    private var filteredAnimations: [AnimationItem] {
        if searchText.isEmpty {
            return store.animations
        }
        return store.animations.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.animations.isEmpty {
                    emptyState
                } else {
                    animationList
                }
            }
            .navigationTitle("Lottie Developer")
            .searchable(text: $searchText, prompt: "Search animations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    importMenu
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType.json, UTType(filenameExtension: "lottie") ?? .json],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .alert("Import from URL", isPresented: $showURLImporter) {
                TextField("https://example.com/animation.json", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Download") {
                    Task { await downloadFromURL() }
                }
                Button("Cancel", role: .cancel) {
                    urlString = ""
                }
            } message: {
                Text("Enter the URL of a Lottie JSON file")
            }
            .alert("Paste JSON", isPresented: $showPasteImporter) {
                TextField("Animation name", text: $pasteName)
                Button("Import") {
                    importFromClipboard(name: pasteName)
                }
                Button("Cancel", role: .cancel) {
                    pasteName = ""
                }
            } message: {
                Text("Give a name for the animation from clipboard")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(importError ?? "Unknown error")
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Animations", systemImage: "film.stack")
        } description: {
            Text("Import Lottie JSON files from Files or a URL to get started.")
        } actions: {
            importMenu
                .buttonStyle(.borderedProminent)
        }
    }

    private var animationList: some View {
        List {
            ForEach(filteredAnimations) { item in
                NavigationLink(value: item) {
                    AnimationRow(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: item.isFavorite ? "star.slash" : "star.fill"
                        )
                    }
                    .tint(.yellow)
                }
            }
        }
        .navigationDestination(for: AnimationItem.self) { item in
            AnimationPlayerView(item: item)
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showFileImporter = true
            } label: {
                Label("Import from Files", systemImage: "folder")
            }

            Button {
                urlString = ""
                showURLImporter = true
            } label: {
                Label("Import from URL", systemImage: "link")
            }

            Button {
                pasteName = ""
                showPasteImporter = true
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: - Import Logic

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    _ = try store.importAnimation(from: url)
                } catch {
                    importError = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                    showError = true
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
            showError = true
        }
    }

    private func importFromClipboard(name: String) {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            importError = "Clipboard is empty or contains no text"
            showError = true
            return
        }

        guard let data = string.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            importError = "Clipboard content is not valid JSON"
            showError = true
            return
        }

        let animationName = name.isEmpty ? "Pasted \(Date.now.formatted(date: .abbreviated, time: .shortened))" : name

        do {
            _ = try store.importAnimation(data: data, name: animationName)
        } catch {
            importError = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
    }

    private func downloadFromURL() async {
        guard let url = URL(string: urlString) else {
            importError = "Invalid URL"
            showError = true
            return
        }

        isDownloading = true
        defer { isDownloading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let name = url.deletingPathExtension().lastPathComponent
            _ = try store.importAnimation(data: data, name: name)
        } catch {
            importError = "Download failed: \(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - Row

struct AnimationRow: View {
    let item: AnimationItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 40, height: 40)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(item.dateAdded, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
