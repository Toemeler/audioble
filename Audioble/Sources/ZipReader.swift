import Compression
import Foundation

enum ZipError: LocalizedError {
    case notAZip
    case unsupportedMethod(UInt16)
    case corrupt(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "Die Datei ist kein ZIP-Archiv."
        case .unsupportedMethod(let method):
            return "Nicht unterstützte ZIP-Komprimierung (Methode \(method))."
        case .corrupt(let detail):
            return "Das ZIP-Archiv ist beschädigt (\(detail))."
        case .checksumMismatch(let name):
            return "Prüfsumme stimmt nicht: \(name)"
        }
    }
}

struct ZipEntry {
    var name: String
    var method: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var headerOffset: UInt64

    var isDirectory: Bool { name.hasSuffix("/") }
}

/// A read-only ZIP reader built on `FileHandle` and the `Compression`
/// framework, so a multi-gigabyte archive never has to be held in memory.
///
/// Supports the two methods that occur in practice - stored (0) and deflate
/// (8) - plus ZIP64, which audiobook archives cross as soon as they pass 4 GB.
/// Audiobook zips are usually stored, because the MP3s inside are already
/// compressed; that path is a plain byte copy.
final class ZipReader {
    private(set) var entries: [ZipEntry] = []
    private let handle: FileHandle
    private let fileSize: UInt64

    /// 64 KiB of comment plus the 22-byte record: the furthest the end-of-
    /// central-directory record can legally sit from the end of the file.
    private static let maxEOCDSearch = 66 * 1024
    private static let chunkSize = 1 << 20

    init(url: URL) throws {
        // Both stored properties are set before anything below can throw, so a
        // rejected archive still unwinds cleanly through deinit.
        handle = try FileHandle(forReadingFrom: url)
        fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize >= 22 else { throw ZipError.notAZip }
        entries = try ZipReader.readCentralDirectory(handle: handle, fileSize: fileSize)
    }

    deinit { try? handle.close() }

    // MARK: - Central directory

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [ZipEntry] {
        let tailLength = Int(min(UInt64(maxEOCDSearch), fileSize))
        try handle.seek(toOffset: fileSize - UInt64(tailLength))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        guard tail.count >= 22 else { throw ZipError.notAZip }

        // Scan backwards: a zip whose comment happens to contain the signature
        // would otherwise be read from the wrong place.
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        var entryCount = UInt64(u16(tail, eocd + 10))
        var directorySize = UInt64(u32(tail, eocd + 12))
        var directoryOffset = UInt64(u32(tail, eocd + 16))

        // Any saturated field means the real values live in the ZIP64 record.
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0,
                  tail[locator] == 0x50, tail[locator + 1] == 0x4B,
                  tail[locator + 2] == 0x06, tail[locator + 3] == 0x07
            else { throw ZipError.corrupt("ZIP64-Locator fehlt") }

            let zip64Offset = u64(tail, locator + 8)
            guard zip64Offset + 56 <= fileSize else { throw ZipError.corrupt("ZIP64-Offset") }
            try handle.seek(toOffset: zip64Offset)
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56,
                  record[0] == 0x50, record[1] == 0x4B, record[2] == 0x06, record[3] == 0x06
            else { throw ZipError.corrupt("ZIP64-EOCD") }

            entryCount = u64(record, 32)
            directorySize = u64(record, 40)
            directoryOffset = u64(record, 48)
        }

        guard directoryOffset + directorySize <= fileSize, directorySize <= 256 << 20 else {
            throw ZipError.corrupt("Verzeichnis-Offset")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else { throw ZipError.corrupt("Verzeichnis kurz") }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 100_000)))
        var p = 0
        while p + 46 <= directory.count {
            guard directory[p] == 0x50, directory[p + 1] == 0x4B,
                  directory[p + 2] == 0x01, directory[p + 3] == 0x02
            else { break }

            let flags = u16(directory, p + 8)
            let method = u16(directory, p + 10)
            let crc = u32(directory, p + 16)
            var compressed = UInt64(u32(directory, p + 20))
            var uncompressed = UInt64(u32(directory, p + 24))
            let nameLength = Int(u16(directory, p + 28))
            let extraLength = Int(u16(directory, p + 30))
            let commentLength = Int(u16(directory, p + 32))
            var headerOffset = UInt64(u32(directory, p + 42))

            let nameStart = p + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw ZipError.corrupt("Eintrag abgeschnitten") }

            let nameBytes = Array(directory[nameStart..<extraStart])
            // Bit 11 promises UTF-8. Without it the spec says CP437, but every
            // modern archiver writes UTF-8 anyway, so try that first.
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1)
                ?? ""
            _ = flags

            // ZIP64 extended information overrides whichever fields saturated.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || headerOffset == 0xFFFF_FFFF {
                var e = extraStart
                while e + 4 <= extraStart + extraLength {
                    let fieldID = u16(directory, e)
                    let fieldSize = Int(u16(directory, e + 2))
                    var f = e + 4
                    guard f + fieldSize <= directory.count else { break }
                    if fieldID == 0x0001 {
                        if uncompressed == 0xFFFF_FFFF, f + 8 <= e + 4 + fieldSize {
                            uncompressed = u64(directory, f); f += 8
                        }
                        if compressed == 0xFFFF_FFFF, f + 8 <= e + 4 + fieldSize {
                            compressed = u64(directory, f); f += 8
                        }
                        if headerOffset == 0xFFFF_FFFF, f + 8 <= e + 4 + fieldSize {
                            headerOffset = u64(directory, f)
                        }
                        break
                    }
                    e += 4 + fieldSize
                }
            }

            if !name.isEmpty {
                entries.append(ZipEntry(
                    name: name,
                    method: method,
                    crc32: crc,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    headerOffset: headerOffset
                ))
            }
            p = next
        }
        guard !entries.isEmpty else { throw ZipError.corrupt("keine Einträge") }
        return entries
    }

    // MARK: - Extraction

    /// Write one entry to `destination`, reporting bytes written as it goes.
    /// `isCancelled` is polled per chunk so a huge import can be stopped.
    func extract(
        _ entry: ZipEntry,
        to destination: URL,
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws {
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupportedMethod(entry.method)
        }
        // The local header repeats the name and carries its own extra field,
        // whose length differs from the central directory's - so the payload
        // offset has to be read from the local header, not computed from it.
        guard entry.headerOffset + 30 <= fileSize else { throw ZipError.corrupt("Header-Offset") }
        try handle.seek(toOffset: entry.headerOffset)
        let local = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard local.count == 30,
              local[0] == 0x50, local[1] == 0x4B, local[2] == 0x03, local[3] == 0x04
        else { throw ZipError.corrupt("lokaler Header") }
        let dataOffset = entry.headerOffset + 30 + UInt64(u16(local, 26)) + UInt64(u16(local, 28))
        guard dataOffset + entry.compressedSize <= fileSize else { throw ZipError.corrupt("Datenbereich") }
        try handle.seek(toOffset: dataOffset)

        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw ZipError.corrupt("Zieldatei")
        }
        let output = try FileHandle(forWritingTo: destination)
        var crc = CRC32()
        var succeeded = false
        defer {
            try? output.close()
            // A half-written chapter is worse than no chapter: it would play
            // as a truncated file instead of failing the import.
            if !succeeded { try? manager.removeItem(at: destination) }
        }

        if entry.method == 0 {
            var remaining = entry.compressedSize
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let want = Int(min(UInt64(Self.chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    throw ZipError.corrupt("unerwartetes Dateiende")
                }
                crc.update(chunk)
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
                progress(Int64(chunk.count))
            }
        } else {
            try inflate(entry, into: output, crc: &crc, progress: progress, isCancelled: isCancelled)
        }

        // A zero CRC in the directory means "written by a streaming producer";
        // everything else is checked.
        if entry.crc32 != 0, crc.value != entry.crc32 {
            throw ZipError.checksumMismatch((entry.name as NSString).lastPathComponent)
        }
        succeeded = true
    }

    private func inflate(
        _ entry: ZipEntry,
        into output: FileHandle,
        crc: inout CRC32,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        // COMPRESSION_ZLIB is Apple's name for raw DEFLATE (RFC 1951), which
        // is exactly what a ZIP member holds - no zlib wrapper to strip.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("Dekomprimierung")
        }
        defer { compression_stream_destroy(stream) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        let sink = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { source.deallocate(); sink.deallocate() }

        var remaining = entry.compressedSize
        stream.pointee.src_ptr = UnsafePointer(source)
        stream.pointee.src_size = 0
        stream.pointee.dst_ptr = sink
        stream.pointee.dst_size = Self.chunkSize

        while true {
            if isCancelled() { throw CancellationError() }

            if stream.pointee.src_size == 0, remaining > 0 {
                let want = Int(min(UInt64(Self.chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    throw ZipError.corrupt("unerwartetes Dateiende")
                }
                chunk.copyBytes(to: UnsafeMutableBufferPointer(start: source, count: chunk.count))
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = chunk.count
                remaining -= UInt64(chunk.count)
            }

            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)

            let produced = Self.chunkSize - stream.pointee.dst_size
            if produced > 0 {
                let out = Data(bytes: sink, count: produced)
                crc.update(out)
                try output.write(contentsOf: out)
                progress(Int64(produced))
                stream.pointee.dst_ptr = sink
                stream.pointee.dst_size = Self.chunkSize
            }

            switch status {
            case COMPRESSION_STATUS_OK:
                // No input left, no output made, not finished: the stream is
                // truncated, and looping again would spin forever.
                if produced == 0, stream.pointee.src_size == 0, remaining == 0 {
                    throw ZipError.corrupt("Datenstrom unvollständig")
                }
            case COMPRESSION_STATUS_END:
                return
            default:
                throw ZipError.corrupt("Dekomprimierung fehlgeschlagen")
            }
        }
    }
}

// MARK: - Little-endian readers

private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    var value: UInt32 = 0
    for i in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[offset + i]) }
    return value
}

private func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    guard offset + 8 <= bytes.count else { return 0 }
    var value: UInt64 = 0
    for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + i]) }
    return value
}

/// Standard CRC-32 (IEEE), computed incrementally over the extracted bytes.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF
    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var c = state
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        state = c
    }
}
