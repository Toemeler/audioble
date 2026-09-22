import SwiftUI

// MARK: - Chapters and clips

struct ChapterListSheet: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            chapterList
                .background(Theme.background)
                .navigationTitle(player.book?.title ?? "Kapitel")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                }
        }
    }

    private var chapterList: some View {
        let chapters = player.book?.chapters ?? []
        return ScrollViewReader { proxy in
            List {
                ForEach(chapters.indices, id: \.self) { index in
                    let chapter = chapters[index]
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
