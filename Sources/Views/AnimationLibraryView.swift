import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AnimationLibraryView: View {
    private enum ClipboardValidationError: Error {
        case invalidJSON
    }

    @Environment(AnimationStore.self) private var store
    @Environment(PurchaseStore.self) private var purchaseStore
    @State private var showFileImporter = false
    @State private var showURLImporter = false
    @State private var showPasteImporter = false
    @State private var showPaywall = false
    @State private var pasteName = ""
    @State private var urlString = ""
    @State private var searchText = ""
    @State private var importError: String?
    @State private var showError = false
    @State private var isDownloading = false
    @State private var isImporting = false

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L10n.string("library.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: L10n.string("library.search.prompt"))
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
                Task { await handleFileImport(result) }
            }
            .alert(L10n.string("library.import.url.title"), isPresented: $showURLImporter) {
                TextField(L10n.string("library.import.url.placeholder"), text: $urlString)
                    #if !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button(L10n.string("library.import.url.download")) {
                    Task { await downloadFromURL() }
                }
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloading || isImporting)
                Button(L10n.string("common.cancel"), role: .cancel) {
                    urlString = ""
                }
            } message: {
                Text(L10n.string("library.import.url.message"))
            }
            .alert(L10n.string("library.import.paste.title"), isPresented: $showPasteImporter) {
                TextField(L10n.string("library.import.paste.namePlaceholder"), text: $pasteName)
                Button(L10n.string("library.import.paste.import")) {
                    Task { await importFromClipboard(name: pasteName) }
                }
                .disabled(isImporting || isDownloading)
                Button(L10n.string("common.cancel"), role: .cancel) {
                    pasteName = ""
                }
            } message: {
                Text(L10n.string("library.import.paste.message"))
            }
            .alert(L10n.string("library.error.title"), isPresented: $showError) {
                Button(L10n.string("library.error.ok")) {}
            } message: {
                Text(importError ?? L10n.string("library.error.unknown"))
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environment(purchaseStore)
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(L10n.string("library.empty.title"))
                    .font(.title3.weight(.semibold))
            }
        } description: {
            Text(L10n.string("library.empty.description"))
        } actions: {
            importMenu
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var animationList: some View {
        List {
            if shouldShowImportHero {
                Section {
                    importHeroCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(filteredAnimations) { item in
                NavigationLink(value: item) {
                    AnimationRow(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label(L10n.string("library.row.delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite
                                ? L10n.string("library.row.unfavorite")
                                : L10n.string("library.row.favorite"),
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
                                ? L10n.string("library.row.unfavorite")
                                : L10n.string("library.row.favorite"),
                            systemImage: item.isFavorite ? "star.slash" : "star.fill"
                        )
                    }

                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label(L10n.string("library.row.delete"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if filteredAnimations.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationDestination(for: AnimationItem.self) { item in
            AnimationPlayerView(item: item)
        }
    }

    private var shouldShowImportHero: Bool {
        !purchaseStore.isPro || store.animations.count <= 1
    }

    private var importHeroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("library.hero.title"))
                .font(.headline)

            Text(
                purchaseStore.isPro
                    ? L10n.string("library.hero.subtitle.pro")
                    : L10n.string("library.hero.subtitle.free")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                requestPrimaryImport()
            } label: {
                Text(
                    purchaseStore.isPro
                        ? L10n.string("library.hero.cta.pro")
                        : L10n.string("library.hero.cta.free")
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.cyan, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var importMenu: some View {
        Menu {
            Button {
                requestImportFiles()
            } label: {
                Label(L10n.string("library.import.files"), systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                requestImportFromURL()
            } label: {
                Label(L10n.string("library.import.url"), systemImage: "link")
            }
            .keyboardShortcut("u", modifiers: .command)

            Button {
                requestImportFromClipboard()
            } label: {
                Label(L10n.string("library.import.paste"), systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        } label: {
            Label(L10n.string("library.import.add"), systemImage: "plus")
        }
        .disabled(isImporting || isDownloading)
    }

    // MARK: - Import Logic

    private func requestPrimaryImport() {
        requestImportFiles()
    }

    private func requestImportFiles() {
        guard purchaseStore.isPro else {
            showPaywall = true
            return
        }
        showFileImporter = true
    }

    private func requestImportFromURL() {
        guard purchaseStore.isPro else {
            showPaywall = true
            return
        }
        urlString = ""
        showURLImporter = true
    }

    private func requestImportFromClipboard() {
        guard purchaseStore.isPro else {
            showPaywall = true
            return
        }
        pasteName = ""
        showPasteImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            isImporting = true
            defer { isImporting = false }

            for url in urls {
                do {
                    _ = try await store.importAnimation(from: url)
                } catch {
                    importError = L10n.format(
                        "library.error.importFailed",
                        url.lastPathComponent,
                        error.localizedDescription
                    )
                    showError = true
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
            showError = true
        }
    }

    private func importFromClipboard(name: String) async {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            importError = L10n.string("library.error.clipboardEmpty")
            showError = true
            return
        }

        let timestamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        let animationName = name.isEmpty
            ? L10n.format("library.paste.defaultName", timestamp)
            : name

        isImporting = true
        defer { isImporting = false }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                guard let data = string.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw ClipboardValidationError.invalidJSON
                }
                return data
            }.value

            _ = try await store.importAnimation(data: data, name: animationName)
            pasteName = ""
        } catch {
            if case ClipboardValidationError.invalidJSON = error {
                importError = L10n.string("library.error.invalidJSON")
            } else {
                importError = L10n.format("library.error.saveFailed", error.localizedDescription)
            }
            showError = true
        }
    }

    private func downloadFromURL() async {
        guard let url = URL(string: urlString) else {
            importError = L10n.string("library.error.invalidURL")
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
            _ = try await store.importAnimation(data: data, name: name)
        } catch let error as URLError where error.code == .timedOut {
            importError = L10n.string("library.error.timeout")
            showError = true
        } catch {
            importError = L10n.format("library.error.downloadFailed", error.localizedDescription)
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
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(item.dateAdded, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
