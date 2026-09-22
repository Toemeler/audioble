import SwiftUI

enum LibraryTab: String, CaseIterable {
    case listening = "Hören"
    case books = "Hörbücher"
    case lists = "Listen"
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @Binding var showPlayer: Bool
    @Binding var showImportSheet: Bool

    @State private var tab: LibraryTab = .books
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recent
    @State private var isGrid = false
    @State private var isSearching = false
    @State private var query = ""
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var editingBook: Book?
    @State private var pendingDeletion: Book?

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Rectangle().fill(Theme.separator).frame(height: 0.5)

            if library.books.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        filterRow
                        countRow
                        if tab == .lists {
                            sectionedContent
                        } else if isGrid {
                            grid(books: visibleBooks)
                        } else {
                            list(books: visibleBooks)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(Theme.background)
        .sheet(item: $editingBook) { book in EditBookSheet(book: book) }
        .confirmationDialog(
            "„\(pendingDeletion?.title ?? "")“ löschen?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let book = pendingDeletion { delete([book.id]) }
                pendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Die Hörbuchdateien werden vom Gerät entfernt.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if isSearching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                    TextField("Titel oder Autor", text: $query)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.primaryText)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Capsule().fill(Theme.surface))

                Button("Abbrechen") {
                    withAnimation { isSearching = false; query = "" }
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.tabAccent)
            } else {
                Spacer()
                Button { withAnimation { isSearching = true } } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    private var tabStrip: some View {
        HStack(spacing: 26) {
            ForEach(LibraryTab.allCases, id: \.self) { item in
                VStack(spacing: 8) {
                    Text(item.rawValue)
                        .font(.system(size: 22, weight: tab == item ? .bold : .regular))
                        .foregroundStyle(tab == item ? Theme.primaryText : Theme.secondaryText)
                    Rectangle()
                        .fill(tab == item ? Theme.tabAccent : Color.clear)
                        .frame(height: 3)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { tab = item } }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - Controls

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Sortierung", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    FilterChipLabel(title: "Filter", systemImage: "slider.horizontal.3", isOn: false)
                }

                FilterChip(
                    title: LibraryFilter.notStarted.label,
                    isOn: filter == .notStarted
                ) { filter = filter == .notStarted ? .all : .notStarted }

                FilterChip(
                    title: LibraryFilter.continueListening.label,
                    isOn: filter == .continueListening
                ) { filter = filter == .continueListening ? .all : .continueListening }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private var countRow: some View {
        HStack(spacing: 14) {
            Text("\(visibleBooks.count) Titel")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Button { isGrid.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                    Text(isGrid ? "Liste" : "Raster")
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Picker("Sortierung", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sort.label)
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
            }

            Button(isSelecting ? "Fertig" : "Auswählen") {
                withAnimation { isSelecting.toggle(); selection.removeAll() }
            }
            .font(.system(size: 15))
            .foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            if isSelecting, !selection.isEmpty {
                Button(role: .destructive) {
                    delete(selection)
                    selection.removeAll()
                } label: {
                    Text("\(selection.count) löschen")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    // MARK: - Content

    private func list(books: [Book]) -> some View {
        ForEach(books) { book in
            BookRow(
                book: book,
                isSelecting: isSelecting,
                isSelected: selection.contains(book.id),
                onTap: { handleTap(book) },
                onPlay: { playOrPause(book) },
                onEdit: { editingBook = book },
                onDelete: { pendingDeletion = book }
            )
            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 110)
        }
    }

    private func grid(books: [Book]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
            spacing: 18
        ) {
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 6) {
                    CoverImage(book: book)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .bottomLeading) {
                            if book.isStarted {
                                ProgressTrack(progress: book.progress, height: 3)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 4)
                            }
                        }
                    Text(book.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { handleTap(book) }
            }
        }
        .padding(.horizontal, 18)
    }

    /// The "Listen" tab: the same books, grouped by where the listener is in them.
    private var sectionedContent: some View {
        let groups: [(String, [Book])] = [
            ("Wird gehört", visibleBooks.filter { $0.isStarted && !$0.isFinished }),
            ("Nicht begonnen", visibleBooks.filter { !$0.isStarted && !$0.isFinished }),
            ("Beendet", visibleBooks.filter(\.isFinished)),
        ].filter { !$0.1.isEmpty }

        return ForEach(groups, id: \.0) { title, books in
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("\(books.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            list(books: books)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Theme.tertiaryText)
            Text("Noch keine Hörbücher")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Importiere ein ZIP-Archiv mit den Kapiteln als MP3.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button { showImportSheet = true } label: {
                Text("Archiv importieren")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 26)
                    .frame(height: 50)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private var visibleBooks: [Book] {
        var books = library.books

        switch tab {
        case .listening: books = books.filter { $0.isStarted && !$0.isFinished }
        case .books, .lists: break
        }

        switch filter {
        case .all: break
        case .notStarted: books = books.filter { !$0.isStarted }
        case .continueListening: books = books.filter { $0.isStarted && !$0.isFinished }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            books = books.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.author.localizedCaseInsensitiveContains(trimmed)
            }
        }

        switch sort {
        case .recent:
            books.sort { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
        case .title:
            books.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            books.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .length:
            books.sort { $0.totalDuration > $1.totalDuration }
        }
        return books
    }

    // MARK: - Actions

    private func handleTap(_ book: Book) {
        if isSelecting {
            if selection.contains(book.id) { selection.remove(book.id) } else { selection.insert(book.id) }
            return
        }
        player.open(book, autoPlay: false)
        showPlayer = true
    }

    private func playOrPause(_ book: Book) {
        if player.book?.id == book.id {
            player.togglePlayPause()
        } else {
            player.open(book, autoPlay: true)
        }
    }

    private func delete(_ ids: Set<UUID>) {
        for id in ids {
            CoverCache.shared.forget(id)
            library.delete(bookID: id)
        }
    }
}

/// The non-button twin of `FilterChip`, so a Menu can use the same look.
private struct FilterChipLabel: View {
    let title: String
    var systemImage: String?
    var isOn: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
            }
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().strokeBorder(Theme.chipBorder, lineWidth: 1))
    }
}

// MARK: - Row

private struct BookRow: View {
    @EnvironmentObject private var player: PlayerEngine

    let book: Book
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                    .padding(.top, 26)
            }

            CoverImage(book: book)
                .frame(width: 76, height: 76)
                .overlay(alignment: .bottomLeading) {
                    // Everything in this library is on the device already, so the
                    // downloaded badge from the design is simply always true here.
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.primaryText, Theme.background.opacity(0.85))
                        .padding(3)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("Autor: \(book.author)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                RowPlayButton(isPlaying: isCurrent && player.isPlaying, action: onPlay)
            }
            .padding(.top, 18)

            Menu {
                Button("Abspielen", systemImage: "play.fill", action: onPlay)
                Button("Von vorn beginnen", systemImage: "gobackward") {
                    LibraryStore.shared.resetProgress(bookID: book.id)
                    if player.book?.id == book.id {
                        player.open(LibraryStore.shared.book(id: book.id) ?? book, autoPlay: false)
                    }
                }
                Button("Als beendet markieren", systemImage: "checkmark.circle") {
                    LibraryStore.shared.markFinished(bookID: book.id)
                }
                Button("Titel bearbeiten", systemImage: "pencil", action: onEdit)
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var isCurrent: Bool { player.book?.id == book.id }

    /// Below the author: a progress bar and what is left, or - for a book not
    /// started yet - simply how long it is.
    @ViewBuilder
    private var statusLine: some View {
        if book.isFinished {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                Text("Beendet")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 2)
        } else if book.isStarted {
            HStack(spacing: 10) {
                ProgressTrack(progress: liveProgress)
                    .frame(width: 92)
                Text("\(liveRemaining.asDurationWords) verbleibend")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.top, 4)
        } else {
            Text(book.totalDuration.asDurationWords)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)
        }
    }

    /// While this book is the one playing, the row follows the playhead rather
    /// than the last saved position.
    private var liveProgress: Double {
        guard isCurrent, book.totalDuration > 0 else { return book.progress }
        return min(1, max(0, (book.totalDuration - player.bookRemaining) / book.totalDuration))
    }

    private var liveRemaining: Double {
        isCurrent ? player.bookRemaining : book.remaining
    }
}

// MARK: - Rename

private struct EditBookSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let book: Book
    @State private var title: String = ""
    @State private var author: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Titel") {
                    TextField("Titel", text: $title)
                }
                Section("Autor") {
                    TextField("Autor", text: $author)
                }
                Section {
                    LabeledContent("Kapitel", value: "\(book.chapters.count)")
                    LabeledContent("Länge", value: book.totalDuration.asDurationWords)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        library.rename(bookID: book.id, title: title, author: author)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { title = book.title; author = book.author }
    }
}
