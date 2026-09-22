import AVFoundation
import Foundation
import GoogleCast

/// Google Cast playback.
///
/// A Chromecast plays media itself from a URL, so casting a locally imported
/// book means three things happening together: `MediaServer` publishes the
/// book's chapters on the LAN, the receiver is told to load that URL, and this
/// object mirrors the receiver's state back so the player screen keeps showing
/// the truth.
///
/// While casting, the phone plays silence. That sounds absurd, but it is what
/// keeps the app alive in the background: iOS only keeps an audio app running
/// while it actually produces audio, and if the app is suspended the HTTP
/// server dies and the receiver stalls mid-chapter.
@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()

    @Published private(set) var isConnected = false
    @Published private(set) var deviceName: String?

    /// Called about once a second with the receiver's position and whether it
    /// is playing, so `PlayerEngine` can follow along.
    var onRemoteState: ((Double, Bool) -> Void)?
    /// The receiver finished the chapter.
    var onRemoteEnded: (() -> Void)?

    private var isStarted = false
    private var token: String?
    private var keepAlive: AVAudioPlayer?
    private var ticker: Timer?
    private var loadedChapter: Int?

    private var client: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    private override init() { super.init() }

    /// Bring up the Cast context. Called once, before any Cast UI exists -
    /// `GCKUICastButton` requires an initialised shared instance.
    func startIfNeeded() {
        guard !isStarted else { return }
        isStarted = true

        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // Discovery only starts once the user opens the picker, so the app does
        // not ask for the local network permission on first launch.
        options.disableDiscoveryAutostart = false
        options.disableAnalyticsLogging = true
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    var isAvailable: Bool {
        guard isStarted, GCKCastContext.isSharedInstanceInitialized() else { return false }
        return GCKCastContext.sharedInstance().castState != .noDevicesAvailable
    }

    // MARK: - Loading

    /// Publish a book on the LAN and hand the receiver the chapter to play.
    func load(book: Book, chapters: [URL], cover: URL?, chapterIndex: Int, startAt: Double, play: Bool) {
        guard isConnected, let client else { return }
        guard chapters.indices.contains(chapterIndex) else { return }

        MediaServer.shared.start()
        let token = self.token ?? MediaServer.shared.publish(chapters: chapters, cover: cover)
        self.token = token

        let fileExtension = chapters[chapterIndex].pathExtension.isEmpty
            ? "mp3" : chapters[chapterIndex].pathExtension
        guard let url = MediaServer.shared.chapterURL(
            token: token, index: chapterIndex, fileExtension: fileExtension
        ) else { return }

        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(book.chapters[chapterIndex].title, forKey: kGCKMetadataKeyTitle)
        metadata.setString(book.title, forKey: kGCKMetadataKeyAlbumTitle)
        metadata.setString(book.author, forKey: kGCKMetadataKeyArtist)
        if let coverURL = MediaServer.shared.coverURL(token: token), cover != nil {
            metadata.addImage(GCKImage(url: coverURL, width: 480, height: 480))
        }

        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .buffered
        builder.contentType = Self.contentType(for: chapters[chapterIndex])
        builder.metadata = metadata
        builder.streamDuration = book.chapters[chapterIndex].duration

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.autoplay = NSNumber(value: play)
        request.startTime = startAt

        loadedChapter = chapterIndex
        client.loadMedia(with: request.build())
    }

    // MARK: - Transport

    func play() { client?.play() }
    func pause() { client?.pause() }

    func seek(to seconds: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = seconds
        options.resumeState = .unchanged
        client?.seek(with: options)
    }

    func setRate(_ rate: Float) {
        client?.setPlaybackRate(rate)
    }

    func endSession() {
        GCKCastContext.sharedInstance().sessionManager.endSession()
    }

    /// Where the receiver currently is, for handing playback back to the phone.
    var remotePosition: Double {
        guard let client else { return 0 }
        let position = client.approximateStreamPosition()
        return position.isFinite && position > 0 ? position : 0
    }

    // MARK: - Mirroring the receiver

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isConnected, let client, let status = client.mediaStatus else { return }
        let playing = status.playerState == .playing || status.playerState == .buffering
        onRemoteState?(remotePosition, playing)

        // The receiver reports idle/finished once a chapter runs out; that is
        // the cue to move on, the same as a local item reaching its end.
        if status.playerState == .idle, status.idleReason == .finished {
            onRemoteEnded?()
        }
    }

    // MARK: - Background keepalive

    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        guard let url = Self.silentTrackURL(),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        keepAlive = player
    }

    private func stopKeepAlive() {
        keepAlive?.stop()
        keepAlive = nil
    }

    /// A one-second silent WAV, written once into the caches directory.
    private static func silentTrackURL() -> URL? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 8000, seconds = 1, channels = 1, bits = 16
        let dataSize = sampleRate * seconds * channels * bits / 8
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }
        func append16(_ value: Int) { data.append(contentsOf: (0..<2).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }

        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(channels)
        append32(sampleRate); append32(sampleRate * channels * bits / 8)
        append16(channels * bits / 8); append16(bits)
        append("data"); append32(dataSize)
        data.append(Data(repeating: 0, count: dataSize))

        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        default: return "audio/mpeg"
        }
    }
}

// MARK: - Session lifecycle

extension CastManager: GCKSessionManagerListener {
    // Explicit selectors: these are @objc protocol methods, and a Swift name
    // that does not match simply never gets called - a silent failure rather
    // than a compile error.
    @objc(sessionManager:didStartSession:)
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        sessionDidConnect(session)
    }

    @objc(sessionManager:didResumeSession:)
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        sessionDidConnect(session)
    }

    @objc(sessionManager:didEndSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        sessionDidDisconnect()
    }

    @objc(sessionManager:didFailToStartSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        sessionDidDisconnect()
    }

    private func sessionDidConnect(_ session: GCKSession) {
        isConnected = true
        deviceName = session.device.friendlyName ?? session.device.deviceID
        token = nil
        MediaServer.shared.start()
        startKeepAlive()
        startTicking()
    }

    private func sessionDidDisconnect() {
        isConnected = false
        deviceName = nil
        token = nil
        ticker?.invalidate()
        ticker = nil
        stopKeepAlive()
        MediaServer.shared.stop()
    }
}
