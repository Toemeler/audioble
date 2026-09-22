import SwiftUI

// MARK: - Chapters and clips

struct ChapterListSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    private enum Page: String, CaseIterable { case chapters = "Kapitel", clips = "Clips" }
    @State private var page: Page = .chapters

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if page == .chapters { chapterList } else { clipList }
            }
            .background(Theme.background)
            .navigationTitle(player.book?.title ?? "Kapitel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array((player.book?.chapters ?? []).enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        player.play(chapterAt: index)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(index == player.chapterIndex ? Theme.accent : Theme.tertiaryText)
                                .frame(width: 26, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapter.title)
                                    .font(.system(size: 16, weight: index == player.chapterIndex ? .bold : .regular))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(2)
                                Text(chapter.duration.asClock)
                                    .font(.system(size: 13).monospacedDigit())
                                    .foregroundStyle(Theme.secondaryText)
                            }

                            Spacer()

                            if index == player.chapterIndex {
                                Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Theme.background)
                    .id(index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(player.chapterIndex, anchor: .center) }
        }
    }

    @ViewBuilder
    private var clipList: some View {
        let book = player.book.flatMap { library.book(id: $0.id) }
        let clips = book?.bookmarks ?? []
        if clips.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "bookmark")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(Theme.tertiaryText)
                Text("Noch keine Clips")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Mit „+ Clip“ im Player merkst du dir eine Stelle.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(clips) { clip in
                    Button {
                        player.play(chapterAt: clip.chapterIndex)
                        player.seek(to: clip.position)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapterTitle(clip.chapterIndex))
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            Text(clip.position.asClock)
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Theme.background)
                }
                .onDelete { offsets in
                    guard let bookID = player.book?.id else { return }
                    for offset in offsets {
                        library.removeBookmark(bookID: bookID, bookmarkID: clips[offset].id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func chapterTitle(_ index: Int) -> String {
        guard let chapters = player.book?.chapters, chapters.indices.contains(index) else {
            return "Kapitel \(index + 1)"
        }
        return chapters[index].title
    }
}

// MARK: - Speed

struct SpeedSheet: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(PlaybackRate.all, id: \.self) { rate in
                    Button {
                        player.rate = rate
                        dismiss()
                    } label: {
                        HStack {
                            Text(PlaybackRate.label(rate))
                                .font(.system(size: 17, weight: rate == player.rate ? .bold : .regular))
                                .foregroundStyle(Theme.primaryText)
                            Spacer()
                            if rate == player.rate {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Geschwindigkeit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Sleep timer

struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    private let options = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                if player.sleepTimerEndsAt != nil || player.sleepAtChapterEnd {
                    Section {
                        HStack {
                            Text(activeLabel).foregroundStyle(Theme.accent)
                            Spacer()
                            Button("Aus") { player.cancelSleepTimer(); dismiss() }
                                .foregroundStyle(Theme.tabAccent)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }

                Section {
                    Button {
                        player.sleepAtEndOfChapter()
                        dismiss()
                    } label: {
                        Text("Ende des Kapitels")
                            .foregroundStyle(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .listRowBackground(Theme.background)

                    ForEach(options, id: \.self) { minutes in
                        Button {
                            player.startSleepTimer(minutes: minutes)
                            dismiss()
                        } label: {
                            Text("\(minutes) Minuten")
                                .foregroundStyle(Theme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .listRowBackground(Theme.background)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Schlummer-Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var activeLabel: String {
        if player.sleepAtChapterEnd { return "Stoppt am Kapitelende" }
        guard let remaining = player.sleepTimerRemaining else { return "" }
        return "Noch \(Int(remaining / 60) + 1) Minuten"
    }
}

// MARK: - Car mode

/// Oversized controls for use while driving: three targets, no small text.
struct CarModeView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 26) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 50, height: 50)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)

                Text(player.chapter?.title ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 20)

                Text("\(player.bookRemaining.asDurationWords) verbleibend")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)

                Spacer()

                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(Color.white)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 78, weight: .medium))
                            .foregroundStyle(Theme.background)
                    }
                    .frame(width: 210, height: 210)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 20) {
                    CarButton(systemName: "gobackward", label: "\(Int(player.skipInterval))") {
                        player.skip(by: -player.skipInterval)
                    }
                    CarButton(systemName: "goforward", label: "\(Int(player.skipInterval))") {
                        player.skip(by: player.skipInterval)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}

private struct CarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface)
                VStack(spacing: 2) {
                    Image(systemName: systemName).font(.system(size: 44, weight: .light))
                    Text(label).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.primaryText)
            }
            .frame(height: 130)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var storage: Int64 = 0
    @State private var confirmDeleteAll = false

    private let skipOptions: [Double] = [10, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("Wiedergabe") {
                    Picker("Sprung", selection: $player.skipInterval) {
                        ForEach(skipOptions, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Picker("Tempo", selection: $player.rate) {
                        ForEach(PlaybackRate.all, id: \.self) {
                            Text(PlaybackRate.label($0)).tag($0)
                        }
                    }
                }

                Section("Bibliothek") {
                    LabeledContent("Hörbücher", value: "\(library.books.count)")
                    LabeledContent(
                        "Speicher",
                        value: ByteCountFormatter().string(fromByteCount: storage)
                    )
                    Button("Alle Hörbücher löschen", role: .destructive) {
                        confirmDeleteAll = true
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text(
                        "Audioble spielt ausschließlich lokal importierte Dateien ab. "
                        + "Es gibt keine Konten, keine Netzwerkzugriffe und keine Analyse."
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .confirmationDialog(
                "Alle Hörbücher löschen?",
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Alles löschen", role: .destructive) {
                    library.deleteAll()
                    storage = 0
                }
                Button("Abbrechen", role: .cancel) {}
            }
        }
        .task { storage = library.storageUsed() }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
