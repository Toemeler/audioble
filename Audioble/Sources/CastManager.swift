import AVFoundation
import Foundation
import GoogleCast
import UIKit

/// Google Cast playback.
///
/// A Chromecast plays media itself from a URL, so casting a locally imported
/// book means three things happening together: `MediaServer` publishes the
/// book's chapters on the LAN, the receiver is told to load that URL, and this
/// object mirrors the receiver's state back so the player screen keeps showing
/// the truth.
///
/// Mirroring is where smoothness lives. The receiver answers every command a
/// moment later, and status that arrives in between still describes the world
/// before the command - so while a command is in flight the receiver's
/// play/pause state is not trusted, and a position is only ever taken from a
/// status that describes the chapter that was actually asked for.
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
    /// Set while a chapter is being handed to the receiver and it has not
    /// started yet, so the player can say so instead of looking frozen.
    @Published private(set) var isLoading = false
    /// The last thing that went wrong, in words for the player screen. Cleared
    /// by the next successful load.
    @Published private(set) var errorMessage: String?

    /// The receiver's position and whether it is playing, several times a
    /// second while connected, so `PlayerEngine` can follow along.
    var onRemoteState: ((Double, Bool) -> Void)?
    /// The receiver played the chapter to its end.
    var onRemoteEnded: (() -> Void)?

    /// What the receiver should be playing: the last load this object issued.
    private struct Loaded {
        var bookID: UUID
        var chapterIndex: Int
        var url: URL
    }

    private var isStarted = false
    private var keepAlive: AVAudioPlayer?
    private var ticker: Timer?
    private var published: (bookID: UUID, token: String)?
    /// The chapter most recently asked for - set at once, while `loaded` is
    /// only set when the request actually goes out.
    private var target: (bookID: UUID, chapterIndex: Int)?
    private var loaded: Loaded?
    /// Bumped by every load, so a load still waiting for the server is
    /// dropped once a newer one has been asked for.
    private var loadGeneration = 0
    /// The receiver's media session for `loaded`, once a status has shown it.
    private var mediaSessionID: Int?
    private var endHandled = false
    /// A seek asked for while the chapter was still loading.
    private var pendingSeek: Double?
    private var loadRequest: GCKRequest?

    /// What the listener last asked for. Reported instead of the receiver's
    /// state while commands are in flight, and while the receiver buffers.
    private var wantsPlaying = false
    private var pendingRequests = 0
    private var trustRemoteAfter = Date.distantPast
    /// The last position that described `loaded`, for the handoff back to the
    /// phone once the session (and with it the client) is gone.
    private var lastKnownPosition: Double = 0

    private var client: GCKRemoteMediaClient? {
        guard GCKCastContext.isSharedInstanceInitialized() else { return nil }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    private override init() { super.init() }

    /// Bring up the Cast context. Called at launch: `GCKUICastButton` needs an
    /// initialised shared instance, and a session left running by the last
    /// launch can only be resumed if the context exists from the start.
    func startIfNeeded() {
        guard !isStarted else { return }
        isStarted = true

        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // Discovery waits for the first tap on the Cast button (the SDK's
        // default), so the local network prompt comes with an explanation
        // rather than on first launch.
        options.disableDiscoveryAutostart = false
        options.startDiscoveryAfterFirstTapOnCastButton = true
        options.disableAnalyticsLogging = true
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // The app stays alive in the background while casting (see the
        // keepalive below); a session suspended there would stop mirroring
        // and stop the chapter from advancing.
        options.suspendSessionsWhenBackgrounded = false
        // "Stop casting" stops the TV too. Otherwise the receiver keeps
        // playing while the phone takes over - the same book twice.
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        observeSystem()
    }

    // MARK: - Loading

    /// Publish a book on the LAN and hand the receiver the chapter to play.
    func load(
        book: Book,
        chapters: [URL],
        cover: URL?,
        chapterIndex: Int,
        startAt: Double,
        play: Bool,
        rate: Float
    ) {
        guard isConnected, chapters.indices.contains(chapterIndex),
              book.chapters.indices.contains(chapterIndex)
        else { return }

        loadGeneration += 1
        let generation = loadGeneration
        target = (book.id, chapterIndex)
        pendingSeek = nil
        wantsPlaying = play
        isLoading = true
        lastKnownPosition = startAt
        holdRemoteState()

        // The listener only knows its port once it is ready, which is a moment
        // after it starts - right when the session has just connected. Wait for
        // it rather than handing the receiver no URL at all.
        MediaServer.shared.start { [weak self] base in
            Task { @MainActor in
                guard let self, generation == self.loadGeneration, self.isConnected else { return }
                guard base != nil else {
                    self.fail("Kein WLAN – der Chromecast kann das Kapitel nicht abrufen.")
                    return
                }
                self.issueLoad(
                    book: book, chapters: chapters, cover: cover,
                    chapterIndex: chapterIndex, startAt: startAt, play: play, rate: rate
                )
            }
        }
    }

    private func issueLoad(
        book: Book,
        chapters: [URL],
        cover: URL?,
        chapterIndex: Int,
        startAt: Double,
        play: Bool,
        rate: Float
    ) {
        guard let client else { return fail("Die Verbindung zum Chromecast ist abgerissen.") }

        let token: String
        if let published, published.bookID == book.id {
            token = published.token
        } else {
            token = MediaServer.shared.publish(chapters: chapters, cover: cover)
            published = (book.id, token)
        }

        let file = chapters[chapterIndex]
        let fileExtension = file.pathExtension.isEmpty ? "mp3" : file.pathExtension
        guard let url = MediaServer.shared.chapterURL(
            token: token, index: chapterIndex, fileExtension: fileExtension
        ) else { return fail("Kein WLAN – der Chromecast kann das Kapitel nicht abrufen.") }

        let chapter = book.chapters[chapterIndex]
        // Music-track metadata: the Default Media Receiver shows title, album
        // and cover for it on every device generation.
        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(chapter.title, forKey: kGCKMetadataKeyTitle)
        metadata.setString(book.title, forKey: kGCKMetadataKeyAlbumTitle)
        metadata.setString(book.author, forKey: kGCKMetadataKeyArtist)
        metadata.setInteger(chapterIndex + 1, forKey: kGCKMetadataKeyTrackNumber)
        if cover != nil, let coverURL = MediaServer.shared.coverURL(token: token) {
            metadata.addImage(GCKImage(url: coverURL, width: 600, height: 600))
        }

        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.contentID = url.absoluteString
        builder.streamType = .buffered
        builder.contentType = Self.contentType(for: file)
        builder.metadata = metadata
        if chapter.duration > 0 { builder.streamDuration = chapter.duration }

        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.autoplay = NSNumber(value: play)
        request.startTime = max(0, startAt)
        request.playbackRate = Self.receiverRate(rate)

        loaded = Loaded(bookID: book.id, chapterIndex: chapterIndex, url: url)
        mediaSessionID = nil
        endHandled = false
        let sent = client.loadMedia(with: request.build())
        loadRequest = sent
        track(sent)
    }

    // MARK: - Transport

    func play() {
        wantsPlaying = true
        // Mid-load the receiver has nothing to resume yet; the wish is applied
        // as soon as the chapter has started (see `tick`).
        guard !isLoading, let client else { return }
        holdRemoteState()
        track(client.play())
    }

    func pause() {
        wantsPlaying = false
        guard !isLoading, let client else { return }
        holdRemoteState()
        track(client.pause())
    }

    func seek(to seconds: Double) {
        lastKnownPosition = max(0, seconds)
        // Mid-load a seek would land on the chapter that is being replaced.
        if isLoading {
            pendingSeek = lastKnownPosition
            return
        }
        guard let client else { return }
        sendSeek(to: lastKnownPosition, on: client)
    }

    private func sendSeek(to seconds: Double, on client: GCKRemoteMediaClient) {
        let options = GCKMediaSeekOptions()
        options.interval = seconds
        options.resumeState = wantsPlaying ? .play : .pause
        holdRemoteState()
        track(client.seek(with: options))
    }

    func setRate(_ rate: Float) {
        guard let client else { return }
        track(client.setPlaybackRate(Self.receiverRate(rate)))
    }

    /// Whether the receiver still has the given chapter loaded and can simply
    /// be told to play, rather than being handed the chapter again.
    /// A load that is still on its way counts: it is about to have it.
    func canResume(bookID: UUID, chapterIndex: Int) -> Bool {
        guard let target, target.bookID == bookID, target.chapterIndex == chapterIndex
        else { return false }
        if isLoading { return true }
        guard let status = client?.mediaStatus, matchesLoaded(status) else { return false }
        return status.playerState != .idle && status.playerState != .unknown
    }

    func endSession() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    /// Where the receiver is, for handing playback back to the phone.
    var remotePosition: Double { lastKnownPosition }

    // MARK: - Mirroring the receiver

    /// Stop believing the receiver's play state until the commands just sent
    /// have been answered.
    private func holdRemoteState() {
        trustRemoteAfter = Date().addingTimeInterval(4)
    }

    private func track(_ request: GCKRequest) {
        pendingRequests += 1
        request.delegate = self
    }

    private func requestFinished() {
        pendingRequests = max(0, pendingRequests - 1)
        if pendingRequests == 0 {
            // The answer's status lands with the completion; a short grace
            // covers a status that is still on its way.
            trustRemoteAfter = min(trustRemoteAfter, Date().addingTimeInterval(0.4))
        }
    }

    private func fail(_ message: String) {
        isLoading = false
        wantsPlaying = false
        errorMessage = message
        onRemoteState?(lastKnownPosition, false)
    }

    /// Whether a status describes the chapter that was last loaded - anything
    /// else is the previous chapter still winding down, or another sender.
    private func matchesLoaded(_ status: GCKMediaStatus) -> Bool {
        guard let loaded else { return false }
        if let info = status.mediaInformation {
            if info.contentURL == loaded.url { return true }
            if info.contentID == loaded.url.absoluteString { return true }
            return false
        }
        // Idle statuses can come without media; the session ID still ties
        // them to the load.
        return mediaSessionID != nil && status.mediaSessionID == mediaSessionID
    }

    private func startTicking() {
        ticker?.invalidate()
        // Four times a second, so the scrubber glides instead of stepping. The
        // position between two statuses is the SDK's own interpolation.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard isConnected, let client, let status = client.mediaStatus, matchesLoaded(status)
        else { return }
        if mediaSessionID == nil, status.mediaSessionID != 0 {
            mediaSessionID = status.mediaSessionID
        }

        switch status.playerState {
        case .playing, .paused:
            if isLoading {
                isLoading = false
                errorMessage = nil
                // Seek, play or pause pressed while the chapter was loading.
                if let seek = pendingSeek {
                    pendingSeek = nil
                    sendSeek(to: seek, on: client)
                } else if (status.playerState == .playing) != wantsPlaying {
                    holdRemoteState()
                    track(wantsPlaying ? client.play() : client.pause())
                }
            }
        case .idle:
            handleIdle(status)
            return
        default:
            break
        }

        // While a seek is in flight the receiver still reports where it was;
        // taking that would yank the scrubber back for a moment.
        let trusted = pendingRequests == 0 && Date() >= trustRemoteAfter
        let position = client.approximateStreamPosition()
        if trusted || isLoading, position.isFinite, position >= 0,
           status.playerState != .loading {
            lastKnownPosition = position
        }

        if trusted {
            switch status.playerState {
            case .playing: wantsPlaying = true
            case .paused: wantsPlaying = false
            default: break   // Buffering and loading keep the intent.
            }
        }
        onRemoteState?(lastKnownPosition, wantsPlaying)
    }

    private func handleIdle(_ status: GCKMediaStatus) {
        switch status.idleReason {
        case .finished:
            // Only once per load: the receiver keeps reporting idle/finished
            // until the next chapter arrives.
            guard !endHandled else { return }
            endHandled = true
            onRemoteEnded?()
        case .error:
            guard !endHandled else { return }
            endHandled = true
            fail("Der Chromecast konnte das Kapitel nicht abspielen.")
        case .cancelled:
            // Stopped from the TV's remote or another phone.
            guard pendingRequests == 0, Date() >= trustRemoteAfter else { return }
            isLoading = false
            wantsPlaying = false
            onRemoteState?(lastKnownPosition, false)
        default:
            break
        }
    }

    // MARK: - Background keepalive

    private func startKeepAlive() {
        if let keepAlive {
            if !keepAlive.isPlaying { keepAlive.play() }
            return
        }
        guard let url = Self.silentTrackURL(),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
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

    /// A phone call stops every player in the app, the silent one included;
    /// without it the app is suspended mid-cast. Start it again afterwards.
    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            MainActor.assumeIsolated { self?.reviveKeepAlive() }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The old player belongs to the audio server that just died.
                self?.keepAlive = nil
                self?.reviveKeepAlive()
            }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveKeepAlive() }
        }
    }

    private func reviveKeepAlive() {
        guard isConnected else { return }
        startKeepAlive()
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

    /// The Default Media Receiver plays 0.5x to 2x; anything outside that is
    /// rejected outright, which would leave the receiver at its old rate.
    private static func receiverRate(_ rate: Float) -> Float {
        min(max(rate, 0.5), 2.0)
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg", "oga", "opus": return "audio/ogg"
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

    @objc(sessionManager:willEndSession:)
    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKSession) {
        // Last chance to read the receiver's position: once the session has
        // ended there is no client left to ask.
        if let client = session.remoteMediaClient, let status = client.mediaStatus,
           matchesLoaded(status) {
            let position = client.approximateStreamPosition()
            if position.isFinite, position >= 0 { lastKnownPosition = position }
        }
    }

    @objc(sessionManager:didEndSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        sessionDidDisconnect()
    }

    @objc(sessionManager:didFailToStartSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        sessionDidDisconnect()
        errorMessage = "Verbindung zum Chromecast fehlgeschlagen."
    }

    private func sessionDidConnect(_ session: GCKSession) {
        session.remoteMediaClient?.add(self)
        deviceName = session.device.friendlyName ?? session.device.modelName
        errorMessage = nil
        startKeepAlive()
        startTicking()
        // Started now so the port is ready by the time the first chapter is
        // handed over.
        MediaServer.shared.start()
        // A resumed session (after a network blip) is the same session; only
        // a new one is a handoff.
        if !isConnected { isConnected = true }
    }

    private func sessionDidDisconnect() {
        ticker?.invalidate()
        ticker = nil
        published = nil
        target = nil
        loaded = nil
        mediaSessionID = nil
        pendingSeek = nil
        loadRequest = nil
        pendingRequests = 0
        isLoading = false
        loadGeneration += 1
        stopKeepAlive()
        MediaServer.shared.stop()
        deviceName = nil
        if isConnected { isConnected = false }
    }
}

// MARK: - Receiver status

extension CastManager: GCKRemoteMediaClientListener {
    @objc(remoteMediaClient:didUpdateMediaStatus:)
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        // React right away instead of waiting for the next tick: a chapter
        // that ends, or a pause pressed on the TV, shows up immediately.
        tick()
    }
}

// MARK: - Requests

extension CastManager: GCKRequestDelegate {
    @objc(requestDidComplete:)
    func requestDidComplete(_ request: GCKRequest) {
        if request === loadRequest { loadRequest = nil }
        requestFinished()
    }

    @objc(request:didFailWithError:)
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        requestFinished()
        // A load that fails leaves the receiver with nothing to play; the
        // other commands failing just means the next status is the truth.
        if request === loadRequest {
            loadRequest = nil
            fail("Der Chromecast konnte das Kapitel nicht laden.")
        }
    }

    @objc(request:didAbortWithReason:)
    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        if request === loadRequest { loadRequest = nil }
        requestFinished()
    }
}
