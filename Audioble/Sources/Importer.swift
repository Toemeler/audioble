import AVFoundation
import Foundation

enum ImportError: LocalizedError {
    case noSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .noSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            return "Zu wenig Speicherplatz: \(formatter.string(fromByteCount: needed)) "
                + "werden gebraucht, frei sind \(formatter.string(fromByteCount: available))."
        }
    }
}

/// Turns a zip of audio files into books in the library.
///
/// Runs entirely off the main actor: a 500 MB archive is streamed chapter by
/// chapter, so memory stays flat and the UI keeps its progress bar moving.
enum Importer {
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "mp4", "flac",
    ]

    static func run(
        archive: URL,
        into root: URL,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> [Book] {
        let archiveName = archive.deletingPathExtension().lastPathComponent
        let reader = try ZipReader(url: archive)

        let audio = reader.entries.filter { entry in
            guard !entry.isDirectory, entry.uncompressedSize > 0 else { return false }
            // macOS resource forks and dotfiles are noise, not chapters.
            guard !entry.name.hasPrefix("__MACOSX/"), !entry.name.contains("/__MACOSX/") else { return false }
            let file = (entry.name as NSString).lastPathComponent
            guard !file.hasPrefix(".") else { return false }
            return audioExtensions.contains((file as NSString).pathExtension.lowercased())
        }
        guard !audio.isEmpty else { return [] }

        let totalBytes = audio.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        try checkSpace(for: totalBytes, at: root)

        // One folder inside the zip is one book, so an archive holding several
        // books imports as several books rather than as one jumbled list.
        var groups: [String: [ZipEntry]] = [:]
        for entry in audio {
            groups[(entry.name as NSString).deletingLastPathComponent, default: []].append(entry)
        }

        var books: [Book] = []
        var writtenBytes: Int64 = 0
        var lastReported = -1.0

        for folder in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            try Task.checkCancellation()
            let entries = groups[folder] ?? []
            let bookTitle = (folder as NSString).lastPathComponent.isEmpty
                ? archiveName
                : (folder as NSString).lastPathComponent

            let bookID = UUID()
            let directory = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            do {
                let book = try await importBook(
                    id: bookID,
                    title: bookTitle,
                    entries: entries,
                    reader: reader,
                    directory: directory,
                    onBytes: { bytes, chapterName, index, count in
                        writtenBytes += bytes
                        let fraction = totalBytes > 0 ? Double(writtenBytes) / Double(totalBytes) : 0
                        // Roughly every half percent: enough for a smooth bar,
                        // few enough hops to the main actor to stay free.
                        guard fraction - lastReported >= 0.005 || fraction >= 1 else { return }
                        lastReported = fraction
                        progress(ImportProgress(
                            fileName: bookTitle,
                            fraction: min(fraction, 1),
                            detail: "Kapitel \(index) von \(count) · \(chapterName)"
                        ))
                    }
                )
                books.append(book)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        progress(ImportProgress(fileName: archiveName, fraction: 1, detail: "Wird abgeschlossen …"))
        return books
    }

    // MARK: - One book

    private static func importBook(
        id: UUID,
        title: String,
        entries: [ZipEntry],
        reader: ZipReader,
        directory: URL,
        onBytes: (Int64, String, Int, Int) -> Void
    ) async throws -> Book {
        // Extract in the zip's own order first; the real chapter order is
        // decided below, once the tags have been read.
        let ordered = entries.sorted { naturalOrder($0.name, $1.name) }
        var extracted: [(entry: ZipEntry, url: URL, fileName: String)] = []
        var usedNames = Set<String>()

        for (offset, entry) in ordered.enumerated() {
            try Task.checkCancellation()
            let fileName = uniqueName(for: entry.name, used: &usedNames)
            let destination = directory.appendingPathComponent(fileName)
            let display = (entry.name as NSString).lastPathComponent
            try reader.extract(
                entry,
                to: destination,
                progress: { bytes in onBytes(bytes, display, offset + 1, ordered.count) },
                isCancelled: { Task.isCancelled }
            )
            extracted.append((entry, destination, fileName))
        }

        // Tags give the chapter titles, the running order and the cover.
        var tags: [String: ID3Tags] = [:]
        var coverFileName: String?
        for item in extracted {
            guard let parsed = ID3.read(url: item.url, includeArtwork: coverFileName == nil) else { continue }
            tags[item.fileName] = parsed
            if coverFileName == nil, let artwork = parsed.artwork {
                let name = "cover.\(parsed.artworkExtension)"
                if (try? artwork.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil {
                    coverFileName = name
                }
            }
        }

        let durations = await self.durations(for: extracted.map { $0.url })

        var chapters: [Chapter] = extracted.enumerated().map { index, item in
            let tag = tags[item.fileName]
            let fallback = (item.entry.name as NSString).lastPathComponent
            return Chapter(
                title: tag?.title ?? prettyTitle(from: fallback),
                fileName: item.fileName,
                duration: durations[index]
            )
        }

        // Track numbers win when the tagger set a complete, unambiguous set;
        // otherwise the filenames decide, compared the way Finder compares
        // them so "10." sorts after "9." rather than after "1.".
        let trackNumbers = extracted.map { tags[$0.fileName]?.track }
        let numbers = trackNumbers.compactMap { $0 }
        if numbers.count == chapters.count, Set(numbers).count == numbers.count {
            chapters = zip(chapters, numbers).sorted { $0.1 < $1.1 }.map { $0.0 }
        }

        let tagged = extracted.compactMap { tags[$0.fileName] }
        let author = tagged.compactMap { $0.albumArtist }.first
            ?? tagged.compactMap { $0.artist }.first
            ?? "Unbekannt"

        return Book(
            id: id,
            title: title,
            author: author,
            chapters: chapters,
            coverFileName: coverFileName
        )
    }

    // MARK: - Durations

    /// Ask AVFoundation for each chapter's length, four files at a time.
    private static func durations(for urls: [URL]) async -> [Double] {
        await withTaskGroup(of: (Int, Double).self) { group in
            var results = [Double](repeating: 0, count: urls.count)
            var next = 0
            while next < min(4, urls.count) {
                let index = next
                let url = urls[index]
                group.addTask { await Importer.duration(of: url, index: index) }
                next += 1
            }
            while let (index, seconds) = await group.next() {
                results[index] = seconds
                if next < urls.count {
                    let index = next
                    let url = urls[index]
                    group.addTask { await Importer.duration(of: url, index: index) }
                    next += 1
                }
            }
            return results
        }
    }

    private static func duration(of url: URL, index: Int) async -> (Int, Double) {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return (index, 0) }
        let seconds = CMTimeGetSeconds(duration)
        return (index, seconds.isFinite && seconds > 0 ? seconds : 0)
    }

    // MARK: - Names

    private static func checkSpace(for needed: Int64, at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Leave the system a little headroom rather than filling the disk.
        guard available - 100 << 20 > needed else {
            throw ImportError.noSpace(needed: needed, available: available)
        }
    }

    /// Flatten the zip path to a single safe file name, keeping it unique
    /// within the book's folder.
    private static func uniqueName(for path: String, used: inout Set<String>) -> String {
        let base = (path as NSString).lastPathComponent
        var cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "chapter.mp3" }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            cleaned = String(cleaned.prefix(110)) + (ext.isEmpty ? "" : ".\(ext)")
        }

        var candidate = cleaned
        var counter = 2
        while used.contains(candidate.lowercased()) {
            let stem = (cleaned as NSString).deletingPathExtension
            let ext = (cleaned as NSString).pathExtension
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// "2. Ein gräßlicher Geburtstag.mp3" -> "Ein gräßlicher Geburtstag",
    /// used only when a file carries no title tag.
    private static func prettyTitle(from fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        if let range = name.range(of: #"^\s*\d+\s*[.\-_)]\s*"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (fileName as NSString).deletingPathExtension : trimmed
    }

    private static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
