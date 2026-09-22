import SwiftUI
import UniformTypeIdentifiers

enum RootTab: Hashable { case library, importing, settings }

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var tab: RootTab = .library
    @State private var showPlayer = false
    @State private var showImportSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            LibraryView(showPlayer: $showPlayer, showImportSheet: $showImportSheet)
                // Leave room for the mini player and the tab bar.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: player.book == nil ? 52 : 118)
                }

            VStack(spacing: 0) {
                if player.book != nil {
                    MiniPlayer { showPlayer = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(selection: $tab) { selected in
                    switch selected {
                    case .library: tab = .library
                    case .importing: showImportSheet = true
                    case .settings: tab = .settings
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: player.book?.id)
        .fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        .sheet(isPresented: $showImportSheet) { ImportSheet() }
        .sheet(isPresented: Binding(
            get: { tab == .settings },
            set: { if !$0 { tab = .library } }
        )) { SettingsSheet() }
        .overlay {
            if let progress = library.importProgress {
                ImportOverlay(progress: progress) { library.cancelImport() }
            }
        }
        .alert(
            "Import fehlgeschlagen",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(library.errorMessage ?? "") }
        )
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selection: RootTab
    let onSelect: (RootTab) -> Void

    private let items: [(tab: RootTab, title: String, icon: String)] = [
        (.library, "Bibliothek", "books.vertical"),
        (.importing, "Importieren", "plus.rectangle.on.folder"),
        (.settings, "Einstellungen", "gearshape"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(items, id: \.tab) { item in
                    Button { onSelect(item.tab) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 19, weight: .regular))
                            Text(item.title).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(selection == item.tab ? Theme.primaryText : Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 9)
        }
        .background(Theme.background)
    }
}

// MARK: - Mini player

private struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerEngine
    let onOpen: () -> Void

    var body: some View {
        if let book = player.book {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverImage(book: book, cornerRadius: 4)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.chapter?.title ?? book.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Text("\(player.bookRemaining.asDurationWords) verbleibend")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)

                    Button { player.skip(by: -player.skipInterval) } label: {
                        SkipGlyph(seconds: Int(player.skipInterval), forward: false, size: 26)
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)

                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle().fill(Color.white)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Theme.background)
                                .offset(x: player.isPlaying ? 0 : 1.5)
                        }
                        .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

                ProgressTrack(progress: chapterProgress, height: 2)
            }
            .background(Theme.background)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
            }
        }
    }

    private var chapterProgress: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }
}

/// The circular-arrow-with-a-number glyph used for the 30-second buttons.
/// SF Symbols only ships fixed numbers, so the number is drawn in the middle.
struct SkipGlyph: View {
    let seconds: Int
    let forward: Bool
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Image(systemName: forward ? "arrow.clockwise" : "arrow.counterclockwise")
                .font(.system(size: size, weight: .light))
            Text("\(seconds)")
                .font(.system(size: size * 0.34, weight: .semibold))
                .offset(y: size * 0.04)
        }
        .frame(width: size * 1.1, height: size * 1.1)
    }
}

// MARK: - Import

private struct ImportSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var archives: [URL] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Button { showFilePicker = true } label: {
                        Label("Archiv aus Dateien wählen", systemImage: "folder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)

                    if !archives.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Im Audioble-Ordner gefunden")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                            ForEach(archives, id: \.self) { url in
                                Button {
                                    library.importArchive(at: url)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.zipper").font(.system(size: 20))
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(2)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.tertiaryText)
                                    }
                                    .foregroundStyle(Theme.primaryText)
                                    .padding(14)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Erwartetes Format")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Text(
                            """
                            Buchtitel.zip
                              └ Buchtitel/
                                  1. Erstes Kapitel.mp3
                                  2. Zweites Kapitel.mp3
                                  …
                            """
                        )
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))

                        Text(
                            "Kapiteltitel, Autor und Cover werden aus den ID3-Tags gelesen; "
                            + "fehlen sie, entscheiden die Dateinamen. Enthält ein Archiv "
                            + "mehrere Ordner, wird jeder davon als eigenes Buch importiert."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryText)

                        Text(
                            "Archive lassen sich auch in der Dateien-App unter "
                            + "„Auf meinem iPhone › Audioble“ ablegen; entpackte "
                            + "Bücher liegen außerhalb dieses Ordners und bleiben "
                            + "aus dem iCloud-Backup heraus."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task { archives = Self.archivesInDocuments() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.importArchive(at: url)
                dismiss()
            }
        }
    }

    /// Zips the listener dropped into the app's own folder from the Files app.
    private static func archivesInDocuments() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

private struct ImportOverlay: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(progress.fileName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                ProgressTrack(progress: progress.fraction, height: 5)
                    .frame(height: 5)

                Text(progress.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text("\(Int(progress.fraction * 100)) %")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)

                Button("Abbrechen", action: onCancel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
            .padding(32)
        }
    }
}
