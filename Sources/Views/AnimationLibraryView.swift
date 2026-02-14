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
            .navigationTitle(String(localized: "library.title"))
            .searchable(text: $searchText, prompt: String(localized: "library.search.prompt"))
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
            .alert(String(localized: "library.import.url.title"), isPresented: $showURLImporter) {
                TextField(String(localized: "library.import.url.placeholder"), text: $urlString)
                    #if !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button(String(localized: "library.import.url.download")) {
                    Task { await downloadFromURL() }
                }
                Button(String(localized: "common.cancel"), role: .cancel) {
                    urlString = ""
                }
            } message: {
                Text("library.import.url.message")
            }
            .alert(String(localized: "library.import.paste.title"), isPresented: $showPasteImporter) {
                TextField(String(localized: "library.import.paste.namePlaceholder"), text: $pasteName)
                Button(String(localized: "library.import.paste.import")) {
                    importFromClipboard(name: pasteName)
                }
                Button(String(localized: "common.cancel"), role: .cancel) {
                    pasteName = ""
                }
            } message: {
                Text("library.import.paste.message")
            }
            .alert(String(localized: "library.error.title"), isPresented: $showError) {
                Button(String(localized: "library.error.ok")) {}
            } message: {
                Text(importError ?? String(localized: "library.error.unknown"))
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "library.empty.title"), systemImage: "film.stack")
        } description: {
            Text("library.empty.description")
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
                        Label(String(localized: "library.row.delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite
                                ? String(localized: "library.row.unfavorite")
                                : String(localized: "library.row.favorite"),
                            systemImage: item.isFavorite ? "star.slash" : "star.fill"
                        )
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite
                                ? String(localized: "library.row.unfavorite")
                                : String(localized: "library.row.favorite"),
                            systemImage: item.isFavorite ? "star.slash" : "star.fill"
                        )
                    }

                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label(String(localized: "library.row.delete"), systemImage: "trash")
                    }
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
                Label(String(localized: "library.import.files"), systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                urlString = ""
                showURLImporter = true
            } label: {
                Label(String(localized: "library.import.url"), systemImage: "link")
            }
            .keyboardShortcut("u", modifiers: .command)

            Button {
                pasteName = ""
                showPasteImporter = true
            } label: {
                Label(String(localized: "library.import.paste"), systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        } label: {
            Label(String(localized: "library.import.add"), systemImage: "plus")
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
                    importError = String(localized: "library.error.importFailed \(url.lastPathComponent) \(error.localizedDescription)")
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
            importError = String(localized: "library.error.clipboardEmpty")
            showError = true
            return
        }

        guard let data = string.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            importError = String(localized: "library.error.invalidJSON")
            showError = true
            return
        }

        let animationName = name.isEmpty
            ? String(localized: "library.paste.defaultName \(Date.now.formatted(date: .abbreviated, time: .shortened))")
            : name

        do {
            _ = try store.importAnimation(data: data, name: animationName)
        } catch {
            importError = String(localized: "library.error.saveFailed \(error.localizedDescription)")
            showError = true
        }
    }

    private func downloadFromURL() async {
        guard let url = URL(string: urlString) else {
            importError = String(localized: "library.error.invalidURL")
            showError = true
            return
        }

        isDownloading = true
        defer { isDownloading = false }

        do {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration)

            let (data, _) = try await session.data(from: url)
            let name = url.deletingPathExtension().lastPathComponent
            _ = try store.importAnimation(data: data, name: name)
        } catch let error as URLError where error.code == .timedOut {
            importError = String(localized: "library.error.timeout")
            showError = true
        } catch {
            importError = String(localized: "library.error.downloadFailed \(error.localizedDescription)")
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
