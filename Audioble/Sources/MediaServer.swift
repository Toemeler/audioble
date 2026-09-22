import Foundation
import Network

/// A minimal HTTP/1.1 file server on the local network.
///
/// A Chromecast fetches media itself and has no access to the app's sandbox, so
/// casting a locally imported audiobook means handing the device a URL it can
/// reach. This serves exactly the chapters of the book currently being cast,
/// behind a random per-session token, and nothing else - there is no directory
/// listing and no way to name a path that is not one of those files.
///
/// It runs only while a cast session is active and is torn down with it.
final class MediaServer {
    static let shared = MediaServer()

    /// What may be fetched right now: one book, addressed by index.
    private struct Route {
        var token: String
        var chapters: [URL]
        var cover: URL?
    }

    private let queue = DispatchQueue(label: "de.toemeler.Audioble.mediaserver")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var route: Route?
    private var boundPort: UInt16?

    private static let chunkSize = 256 * 1024

    private init() {}

    // MARK: - Lifecycle

    /// Start listening on an ephemeral port. Safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        let running = listener != nil
        lock.unlock()
        if running { return true }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // The Chromecast is on the LAN, so the socket must be too.
        parameters.requiredInterfaceType = .wifi

        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = listener.port else { return }
            self?.lock.lock()
            self?.boundPort = port.rawValue
            self?.lock.unlock()
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
        return true
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let open = connections
        self.listener = nil
        connections.removeAll()
        route = nil
        boundPort = nil
        lock.unlock()

        listener?.cancel()
        for connection in open.values { connection.cancel() }
    }

    /// Publish a book for the duration of a cast session and return the token
    /// its URLs are built from.
    @discardableResult
    func publish(chapters: [URL], cover: URL?) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        lock.lock()
        route = Route(token: token, chapters: chapters, cover: cover)
        lock.unlock()
        return token
    }

    var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    /// The base URL a Chromecast on the same network can reach, or nil while
    /// the listener has no port or the device has no Wi-Fi address.
    func baseURL() -> URL? {
        guard let port = port, let address = Self.wifiAddress() else { return nil }
        return URL(string: "http://\(address):\(port)")
    }

    func chapterURL(token: String, index: Int, fileExtension: String) -> URL? {
        guard let base = baseURL() else { return nil }
        return base.appendingPathComponent("\(token)/chapter/\(index).\(fileExtension)")
    }

    func coverURL(token: String) -> URL? {
        guard let base = baseURL() else { return nil }
        return base.appendingPathComponent("\(token)/cover.jpg")
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        lock.lock()
        connections[key] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.forget(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.lock()
        connections[key] = nil
        lock.unlock()
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        forget(ObjectIdentifier(connection))
    }

    /// Read until the end of the request head. Bodies are not read: this server
    /// answers GET and HEAD only.
    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else { self.close(connection); return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            // A request head this long is not one this server serves.
            guard !isComplete, buffer.count < 16384 else { self.close(connection); return }
            self.readRequest(on: connection, buffer: buffer)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return close(connection) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return close(connection) }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            return send(status: 405, headers: ["Allow": "GET, HEAD"], body: nil, on: connection)
        }

        let path = String(parts[1])
        guard let file = resolve(path: path) else {
            return send(status: 404, headers: [:], body: Data("Not found".utf8), on: connection)
        }

        var rangeHeader: String?
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            if pieces[0].lowercased() == "range" {
                rangeHeader = pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        serve(file: file, range: rangeHeader, headOnly: method == "HEAD", on: connection)
    }

    /// Map a request path to a file. Only the published book's own chapters and
    /// cover can be named; nothing is resolved against the filesystem.
    private func resolve(path: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let route else { return nil }

        let components = path
            .split(separator: "?", maxSplits: 1)[0]
            .split(separator: "/")
            .map(String.init)
        guard components.count >= 2, components[0] == route.token else { return nil }

        if components.count == 2, components[1].hasPrefix("cover") {
            return route.cover
        }
        guard components.count == 3, components[1] == "chapter" else { return nil }
        let name = (components[2] as NSString).deletingPathExtension
        guard let index = Int(name), route.chapters.indices.contains(index) else { return nil }
        return route.chapters[index]
    }

    // MARK: - Sending

    private func serve(file: URL, range: String?, headOnly: Bool, on connection: NWConnection) {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey])
        guard let total = values?.fileSize, total > 0,
              let handle = try? FileHandle(forReadingFrom: file)
        else {
            return send(status: 404, headers: [:], body: Data("Not found".utf8), on: connection)
        }

        var start = 0
        var end = total - 1
        var status = 200
        if let range, let parsed = Self.parseRange(range, total: total) {
            start = parsed.lowerBound
            end = parsed.upperBound
            status = 206
        } else if range != nil {
            try? handle.close()
            return send(
                status: 416,
                headers: ["Content-Range": "bytes */\(total)"],
                body: nil,
                on: connection
            )
        }

        let length = end - start + 1
        var headers: [String: String] = [
            "Content-Type": Self.contentType(for: file),
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
            "Connection": "close",
        ]
        if status == 206 {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }

        connection.send(content: Data(Self.headerData(status: status, headers: headers)), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil, !headOnly else {
                try? handle.close()
                self.close(connection)
                return
            }
            try? handle.seek(toOffset: UInt64(start))
            self.sendBody(handle: handle, remaining: length, on: connection)
        })
    }

    /// Send the body a block at a time, each block only once the previous one
    /// has been handed to the network - which is what keeps a whole chapter
    /// from being buffered in memory.
    private func sendBody(handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            close(connection)
            return
        }
        let want = min(Self.chunkSize, remaining)
        guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else {
            try? handle.close()
            close(connection)
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                try? handle.close()
                self.close(connection)
                return
            }
            self.sendBody(handle: handle, remaining: remaining - chunk.count, on: connection)
        })
    }

    private func send(status: Int, headers: [String: String], body: Data?, on connection: NWConnection) {
        var headers = headers
        headers["Content-Length"] = "\(body?.count ?? 0)"
        headers["Connection"] = "close"
        var data = Data(Self.headerData(status: status, headers: headers))
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private static func headerData(status: Int, headers: [String: String]) -> [UInt8] {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return Array(text.utf8)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        default: return "Error"
        }
    }

    /// "bytes=0-", "bytes=500-999", "bytes=-500" - the forms a player sends.
    static func parseRange(_ header: String, total: Int) -> ClosedRange<Int>? {
        guard total > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        // Only the first range of a multi-range request is honoured, which is
        // all a media player ever asks for.
        let spec = trimmed.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2 else { return nil }

        let first = Int(pieces[0])
        let last = Int(pieces[1])

        var start: Int
        var end: Int
        switch (first, last) {
        case (nil, let suffix?):
            // "bytes=-500": the last 500 bytes.
            guard suffix > 0 else { return nil }
            start = max(0, total - suffix)
            end = total - 1
        case (let from?, nil):
            guard from < total else { return nil }
            start = from
            end = total - 1
        case (let from?, let to?):
            guard from <= to, from < total else { return nil }
            start = from
            end = min(to, total - 1)
        default:
            return nil
        }
        guard start <= end else { return nil }
        return start...end
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    /// The device's Wi-Fi IPv4 address - the only one a Chromecast can reach.
    static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var result: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            result = String(cString: host)
            break
        }
        return result
    }
}
