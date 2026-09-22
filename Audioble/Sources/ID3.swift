import Foundation

/// The metadata an audiobook chapter carries: a chapter title, its place in
/// the book, the book's own title and author, and the cover art.
struct ID3Tags {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var track: Int?
    var artwork: Data?
    var artworkExtension: String = "jpg"
}

/// A minimal ID3v2 reader (v2.2, v2.3 and v2.4) covering exactly the frames
/// this app displays.
///
/// AVFoundation can read these too, but only by opening and parsing the whole
/// asset; reading the tag directly means touching just the first few hundred
/// kilobytes of each chapter, which is what keeps importing a 500 MB book fast.
enum ID3 {
    /// Cap the tag read: a tag is normally well under a megabyte, and the cover
    /// art is the only large frame in it.
    private static let maxTagSize = 16 << 20

    static func read(url: URL, includeArtwork: Bool = true) -> ID3Tags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        let head = [UInt8](header)
        guard head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return nil }  // "ID3"

        let major = head[3]
        guard major >= 2, major <= 4 else { return nil }
        let flags = head[5]
        let size = synchsafe(head, 6)
        guard size > 0, size <= maxTagSize else { return nil }

        guard let bodyData = try? handle.read(upToCount: size), bodyData.count > 0 else { return nil }
        var body = [UInt8](bodyData)

        // Tag-level unsynchronisation: every 0xFF 0x00 pair in the body stands
        // for a literal 0xFF that was escaped so it could not look like a frame sync.
        if flags & 0x80 != 0 { body = deunsynchronise(body) }

        var offset = 0
        if flags & 0x40 != 0 {
            // v2.4 states a synchsafe size that includes itself; v2.3 a plain
            // size that does not.
            guard body.count >= 4 else { return nil }
            offset = major == 4 ? synchsafe(body, 0) : be32(body, 0) + 4
            guard offset >= 0, offset < body.count else { return nil }
        }

        var tags = ID3Tags()
        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10

        while offset + headerLength <= body.count {
            let idBytes = Array(body[offset..<offset + idLength])
            // Padding after the last frame is zero bytes.
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            guard let id = String(bytes: idBytes, encoding: .isoLatin1) else { break }

            var frameSize: Int
            var frameFlags: UInt16 = 0
            switch major {
            case 2:
                frameSize = (Int(body[offset + 3]) << 16) | (Int(body[offset + 4]) << 8) | Int(body[offset + 5])
            case 3:
                frameSize = be32(body, offset + 4)
                frameFlags = UInt16(body[offset + 8]) << 8 | UInt16(body[offset + 9])
            default:
                frameSize = synchsafe(body, offset + 4)
                frameFlags = UInt16(body[offset + 8]) << 8 | UInt16(body[offset + 9])
            }

            let payloadStart = offset + headerLength
            guard frameSize > 0, payloadStart + frameSize <= body.count else { break }
            var payload = Array(body[payloadStart..<payloadStart + frameSize])
            offset = payloadStart + frameSize

            if major == 4 {
                // A data-length indicator prefixes the payload with the size it
                // will have once decoded; skip it.
                if frameFlags & 0x0001 != 0, payload.count >= 4 { payload.removeFirst(4) }
                if frameFlags & 0x0002 != 0 { payload = deunsynchronise(payload) }
            }
            // Compressed or encrypted frames are not something an audiobook
            // tagger produces; skipping beats mis-decoding them.
            if major >= 3, frameFlags & 0x000C != 0 { continue }

            switch id {
            case "TIT2", "TT2": tags.title = text(payload)
            case "TPE1", "TP1": tags.artist = text(payload)
            case "TALB", "TAL": tags.album = text(payload)
            case "TPE2", "TP2": tags.albumArtist = text(payload)
            case "TRCK", "TRK": tags.track = trackNumber(text(payload))
            case "APIC", "PIC":
                guard includeArtwork else { break }
                if let picture = picture(payload, isV22: major == 2) {
                    // Prefer the front cover; otherwise keep the first picture found.
                    if tags.artwork == nil || picture.isFrontCover {
                        tags.artwork = picture.data
                        tags.artworkExtension = picture.fileExtension
                    }
                }
            default: break
            }
        }
        return tags
    }

    // MARK: - Frame payloads

    private static func text(_ payload: [UInt8]) -> String? {
        guard let encoding = payload.first else { return nil }
        var bytes = Array(payload.dropFirst())
        // Trailing terminators are part of the format, not of the string.
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        let value = decode(bytes, encoding: encoding)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func decode(_ bytes: [UInt8], encoding: UInt8) -> String? {
        switch encoding {
        case 0: return String(bytes: bytes, encoding: .isoLatin1)
        case 1:
            // UTF-16 with a byte-order mark.
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
                return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
                return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
            return String(bytes: bytes, encoding: .utf16LittleEndian)
        case 2: return String(bytes: bytes, encoding: .utf16BigEndian)
        default: return String(bytes: bytes, encoding: .utf8)
                    ?? String(bytes: bytes, encoding: .isoLatin1)
        }
    }

    private struct Picture {
        var data: Data
        var fileExtension: String
        var isFrontCover: Bool
    }

    private static func picture(_ payload: [UInt8], isV22: Bool) -> Picture? {
        guard let encoding = payload.first else { return nil }
        var index = 1
        var fileExtension = "jpg"

        if isV22 {
            // Three characters of image format: "JPG", "PNG".
            guard payload.count > 4 else { return nil }
            let format = String(bytes: payload[1..<4], encoding: .isoLatin1)?.lowercased() ?? "jpg"
            fileExtension = format.contains("png") ? "png" : "jpg"
            index = 4
        } else {
            // MIME type, always Latin-1, null terminated.
            var end = index
            while end < payload.count, payload[end] != 0 { end += 1 }
            guard end < payload.count else { return nil }
            let mime = String(bytes: payload[index..<end], encoding: .isoLatin1)?.lowercased() ?? ""
            fileExtension = mime.contains("png") ? "png" : "jpg"
            index = end + 1
        }

        guard index < payload.count else { return nil }
        let pictureType = payload[index]
        index += 1

        // The description is terminated in the frame's own text encoding, so a
        // UTF-16 description ends with two zero bytes on an even boundary.
        if encoding == 1 || encoding == 2 {
            var end = index
            while end + 1 < payload.count, !(payload[end] == 0 && payload[end + 1] == 0) { end += 2 }
            index = min(end + 2, payload.count)
        } else {
            var end = index
            while end < payload.count, payload[end] != 0 { end += 1 }
            index = min(end + 1, payload.count)
        }

        guard index < payload.count else { return nil }
        let data = Data(payload[index...])
        guard data.count > 100 else { return nil }
        return Picture(data: data, fileExtension: fileExtension, isFrontCover: pictureType == 3)
    }

    /// "7", "07", "7/19" - all mean chapter seven.
    private static func trackNumber(_ value: String?) -> Int? {
        guard let head = value?.split(separator: "/").first else { return nil }
        return Int(head.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Integers

    /// ID3 sizes use seven bits per byte so they can never contain a frame sync.
    private static func synchsafe(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        var value = 0
        for i in 0..<4 { value = (value << 7) | Int(bytes[offset + i] & 0x7F) }
        return value
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        var value = 0
        for i in 0..<4 { value = (value << 8) | Int(bytes[offset + i]) }
        return value
    }

    private static func deunsynchronise(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }
}
