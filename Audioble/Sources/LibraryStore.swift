import AVFoundation
import Foundation

/// What the import sheet shows while a zip is being unpacked.
struct ImportProgress: Equatable {
    var fileName: String
    var fraction: Double
    var detail: String
}

/// The library: the books on disk, their listening positions, and the importer
/// that puts them there. Everything is local - there is no account, no network
/// call and no server anywhere in this app.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var books: [Book] = []
    @Published var importProgress: ImportProgress?
    @Published var errorMessage: String?

    private var importTask: Task<Void, Never>?
    private var saveWorkItem: Task<Void, Never>?

    /// Application Support rather than Documents: the listener's own folder in
    /// the Files app then holds only the archives they put there, not a pile of
    /// UUID-named chapter folders. Zips are still picked up from Documents.
    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Books", isDirectory: true)
    }()

    private var indexURL: URL { root.appendingPathComponent("library.json") }

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup()
        load()
    }

    /// A library of audiobooks is re-importable bulk, and a few hundred
    /// megabytes per book would otherwise be pushed into the listener's iCloud
    /// backup.
    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Paths

    func directory(for book: Book) -> URL {
        root.appendingPathComponent(book.id.uuidString, isDirectory: true)
    }

    func url(for chapter: Chapter, in book: Book) -> URL {
        directory(for: book).appendingPathComponent(chapter.fileName)
    }

    func coverURL(for book: Book) -> URL? {
        guard let name = book.coverFileName else { return nil }
        let url = directory(for: book).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Book].self, from: data) else { return }
        // Drop entries whose folder was removed behind the app's back, so a
        // stale row can never open into a player with nothing to play.
        books = stored.filter { FileManager.default.fileExists(atPath: directory(for: $0).path) }
        if books.count != stored.count { save() }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(books) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Atomic: a crash mid-write must not cost the listener every position.
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Position updates arrive about once a second while playing; batching them
    /// keeps the write off the playback path.
    private func saveSoon() {
        saveWorkItem?.cancel()
        saveWorkItem = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: - Mutations

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    func updateProgress(bookID: UUID, chapterIndex: Int, position: Double, immediate: Bool = false) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].chapterIndex = chapterIndex
        books[index].position = position
        books[index].lastPlayedAt = Date()
        if books[index].isFinished, !books[index].isNowComplete { books[index].isFinished = false }
        immediate ? save() : saveSoon()
    }

    func markFinished(bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].isFinished = true
        books[index].lastPlayedAt = Date()
        save()
    }

    func resetProgress(bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].chapterIndex = 0
        books[index].position = 0
        books[index].isFinished = false
        save()
    }

    func rename(bookID: UUID, title: String, author: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { books[index].title = title }
        books[index].author = author
        save()
    }

    /// Bytes the library occupies, for the settings screen.
    func storageUsed() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    func deleteAll() {
        let directories = books.map { directory(for: $0) }
        books.removeAll()
        save()
        Task.detached(priority: .utility) {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    func delete(bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let book = books[index]
        books.remove(at: index)
        save()
        let directory = directory(for: book)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Import

    func cancelImport() {
        importTask?.cancel()
    }

    /// Unpack a zip into the library. Accepts a security-scoped URL from the
    /// file picker, from "Copy to Audioble", or from the app's own Documents
    /// folder; the archive itself is read in place and never copied.
    func importArchive(at url: URL) {
        guard importProgress == nil else { return }
        importProgress = ImportProgress(
            fileName: url.deletingPathExtension().lastPathComponent,
            fraction: 0,
            detail: "Archiv wird gelesen …"
        )

        importTask = Task { [weak self] in
            guard let self else { return }
            let root = self.root
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let imported = try await Importer.run(archive: url, into: root) { progress in
                    Task { @MainActor [weak self] in self?.importProgress = progress }
                }
                guard !Task.isCancelled else { return }
                self.books.append(contentsOf: imported)
                self.save()
                self.importProgress = nil
                if imported.isEmpty {
                    self.errorMessage = "In diesem Archiv wurden keine Audiodateien gefunden."
                }
            } catch is CancellationError {
                self.importProgress = nil
            } catch {
                self.importProgress = nil
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

private extension Book {
    /// True once the playhead sits at the very end of the last chapter.
    var isNowComplete: Bool {
        chapterIndex >= chapters.count - 1
            && position >= (chapters.last?.duration ?? 0) - 1
    }
}
