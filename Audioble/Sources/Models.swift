import Foundation

/// One audio file inside a book. `fileName` is relative to the book's folder,
/// so the library survives the container path changing between installs.
struct Chapter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var duration: Double
}

struct Book: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var author: String
    var chapters: [Chapter]
    var coverFileName: String?
    var addedAt: Date = Date()

    // Where the listener stopped. Persisted on every pause, chapter change,
    // backgrounding and every few seconds of playback.
    var chapterIndex: Int = 0
    var position: Double = 0
    var lastPlayedAt: Date?
    var isFinished: Bool = false

    // Decoded by hand so a library written by another build - one with a field
    // this one no longer has, or missing one it gained - still opens instead of
    // being thrown away. The synthesized decoder ignores default values and
    // would fail on a missing key.
    enum CodingKeys: String, CodingKey {
        case id, title, author, chapters, coverFileName, addedAt
        case chapterIndex, position, lastPlayedAt, isFinished
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        chapters: [Chapter],
        coverFileName: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.chapters = chapters
        self.coverFileName = coverFileName
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Ohne Titel"
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? "Unbekannt"
        chapters = try container.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        coverFileName = try container.decodeIfPresent(String.self, forKey: .coverFileName)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        isFinished = try container.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
    }

    var totalDuration: Double { chapters.reduce(0) { $0 + $1.duration } }

    /// Seconds of the whole book already behind the playhead.
    var elapsed: Double {
        guard chapters.indices.contains(chapterIndex) else { return 0 }
        let before = chapters.prefix(chapterIndex).reduce(0) { $0 + $1.duration }
        return before + min(position, chapters[chapterIndex].duration)
    }

    var remaining: Double { max(0, totalDuration - elapsed) }

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, elapsed / totalDuration))
    }

    /// A book is "begun" once the listener is past the first seconds of it -
    /// opening the player by accident should not move it out of "Nicht begonnen".
    var isStarted: Bool { chapterIndex > 0 || position > 30 }
}

/// How the library list is filtered and ordered. Both are driven by the
/// controls in the header, so every control in the design does something.
enum LibraryFilter: String, CaseIterable {
    case all, notStarted, continueListening

    var label: String {
        switch self {
        case .all: return "Alle"
        case .notStarted: return "Nicht begonnen"
        case .continueListening: return "Weiterhören"
        }
    }
}

enum LibrarySort: String, CaseIterable {
    case recent, title, author, length

    var label: String {
        switch self {
        case .recent: return "Zuletzt"
        case .title: return "Titel"
        case .author: return "Autor"
        case .length: return "Länge"
        }
    }
}
