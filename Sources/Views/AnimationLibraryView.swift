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
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(L10n.string("library.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
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
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(L10n.string("library.empty.title"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }

            Text(L10n.string("library.empty.description"))
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                requestPrimaryImport()
            } label: {
                Group {
                    if purchaseStore.isPro {
                        Text(L10n.string("library.hero.cta.pro"))
                    } else {
                        Text(L10n.string("library.hero.cta.free"))
                    }
                }
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.accentGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .appGlassCard(cornerRadius: 24, fillOpacity: 0.09, borderOpacity: 0.18)
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
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            ForEach(filteredAnimations) { item in
                NavigationLink(value: item) {
                    AnimationRow(item: item)
                }
                .listRowBackground(AppTheme.surfaceEmphasis)
                .listRowSeparatorTint(AppTheme.borderSoft)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label(L10n.string("library.row.delete"), systemImage: "trash.fill")
                    }
                    .tint(.red)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        store.toggleFavorite(item)
                    } label: {
                        Label(
                            item.isFavorite
                                ? L10n.string("library.row.unfavorite")
                                : L10n.string("library.row.favorite"),
                            systemImage: item.isFavorite ? "star.slash.fill" : "star.fill"
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
        .scrollContentBackground(.hidden)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.animations.count)
        .overlay {
            if filteredAnimations.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationDestination(for: AnimationItem.self) { item in
            AnimationPlayerView(item: item)
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(AppTheme.textSecondary)

                TextField(L10n.string("library.search.prompt"), text: $searchText)
                    .font(.body)
                    .foregroundStyle(AppTheme.textPrimary)
                    .autocorrectionDisabled()
                    #if !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    #endif

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(AppTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )

            importMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(Color.clear)
    }

    private var shouldShowImportHero: Bool {
        !purchaseStore.isPro || store.animations.count <= 1
    }

    private var importHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(6)
                    .background(
                        LinearGradient(
                            colors: [AppTheme.accentStart.opacity(0.42), AppTheme.accentEnd.opacity(0.38)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                Text(L10n.string("library.hero.title"))
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(
                purchaseStore.isPro
                    ? L10n.string("library.hero.subtitle.pro")
                    : L10n.string("library.hero.subtitle.free")
            )
            .font(.subheadline)
            .foregroundStyle(AppTheme.textPrimary.opacity(0.82))

            Button {
                requestPrimaryImport()
            } label: {
                Group {
                    if purchaseStore.isPro {
                        Text(L10n.string("library.hero.cta.pro"))
                    } else {
                        Text(L10n.string("library.hero.cta.free"))
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(
                        colors: [AppTheme.accentStart.opacity(0.86), AppTheme.accentEnd.opacity(0.86)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundStyle(.white.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: AppTheme.accentEnd.opacity(0.24), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.26), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
        )
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 8)
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
            ZStack {
                Circle()
                    .fill(AppTheme.surfaceEmphasis)

                Circle()
                    .stroke(AppTheme.border, lineWidth: 1)

                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .accessibilityLabel(L10n.string("library.import.add"))
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
            Image(systemName: "waveform.circle.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(
                        colors: [.cyan.opacity(0.15), .blue.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .animation(.spring(response: 0.3), value: item.isFavorite)
                    }
                }

                Text(item.dateAdded, style: .date)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}
