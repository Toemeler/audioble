import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Playback for one book at a time: chapter queueing, autoplay into the next
/// chapter, position keeping, speed, sleep timer and the lock-screen controls.
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var book: Book?
    @Published private(set) var chapterIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var sleepTimerEndsAt: Date?
    @Published private(set) var sleepAtChapterEnd = false
    @Published var rate: Float = UserDefaults.standard.playbackRate {
        didSet {
            UserDefaults.standard.playbackRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    /// The scrubber owns the displayed time while a drag is in flight, so the
    /// periodic observer cannot yank the thumb back under the finger.
    private(set) var isScrubbing = false

    /// How far the two round buttons jump. Configurable, because 30 seconds
    /// suits a novel and 10 suits a dense non-fiction chapter.
    @Published var skipInterval: Double = UserDefaults.standard.skipInterval {
        didSet {
            UserDefaults.standard.skipInterval = skipInterval
            let commands = MPRemoteCommandCenter.shared()
            commands.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        }
    }

    private let player = AVPlayer()
    private let library = LibraryStore.shared
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sleepTicker: Timer?
    private var artworkCache: (bookID: UUID, artwork: MPMediaItemArtwork)?
    private var lastPersist = Date.distantPast

    var chapter: Chapter? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var hasNextChapter: Bool { (book?.chapters.count ?? 0) > chapterIndex + 1 }
    var hasPreviousChapter: Bool { chapterIndex > 0 }

    /// Seconds left in the whole book, not just the chapter.
    var bookRemaining: Double {
        guard let book else { return 0 }
        let after = book.chapters.dropFirst(chapterIndex + 1).reduce(0) { $0 + $1.duration }
        return max(0, after + max(0, duration - currentTime))
    }

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        observeSystem()
    }

    // MARK: - Opening a book

    /// Load a book and restore where the listener stopped. Playback starts only
    /// when `autoPlay` is set, so tapping a row opens the player without noise.
    func open(_ book: Book, autoPlay: Bool) {
        if self.book?.id == book.id {
            if autoPlay, !isPlaying { play() }
            return
        }
        persistPosition(immediate: true)

        self.book = book
        // A finished book starts over rather than opening at its last second.
        let restart = book.isFinished || book.chapterIndex >= book.chapters.count
        chapterIndex = restart ? 0 : book.chapterIndex
        let start = restart ? 0 : book.position
        load(chapterIndex: chapterIndex, startAt: start, play: autoPlay)
    }

    private func load(chapterIndex index: Int, startAt time: Double, play shouldPlay: Bool) {
        guard let book, book.chapters.indices.contains(index) else { return }
        chapterIndex = index
        let chapter = book.chapters[index]
        duration = chapter.duration
        currentTime = min(max(0, time), max(0, chapter.duration))

        let item = AVPlayerItem(url: library.url(for: chapter, in: book))
        player.replaceCurrentItem(with: item)
        if currentTime > 0 {
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if shouldPlay { play() } else { updateNowPlaying() }
    }

    // MARK: - Transport

    func play() {
        guard book != nil else { return }
        activateSession()
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition(immediate: true)
        updateNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    /// The two 30-second buttons. Rolls over into the neighbouring chapter
    /// instead of sticking at a chapter boundary.
    func skip(by seconds: Double) {
        guard book != nil else { return }
        let target = currentTime + seconds
        if target < 0, hasPreviousChapter {
            let previous = chapterIndex - 1
            let previousDuration = book?.chapters[previous].duration ?? 0
            load(chapterIndex: previous, startAt: max(0, previousDuration + target), play: isPlaying)
            return
        }
        if target > duration, hasNextChapter {
            load(chapterIndex: chapterIndex + 1, startAt: target - duration, play: isPlaying)
            return
        }
        seek(to: min(max(0, target), duration))
    }

    func seek(to time: Double) {
        guard book != nil else { return }
        let target = min(max(0, time), max(0, duration))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        persistPosition(immediate: true)
        updateNowPlaying()
    }

    func nextChapter() {
        guard hasNextChapter else { return }
        load(chapterIndex: chapterIndex + 1, startAt: 0, play: isPlaying)
        persistPosition(immediate: true)
    }

    /// Restarts the chapter first, the way every audiobook player does, and
    /// only steps back a chapter when already near its beginning.
    func previousChapter() {
        if currentTime > 5 || !hasPreviousChapter {
            seek(to: 0)
            return
        }
        load(chapterIndex: chapterIndex - 1, startAt: 0, play: isPlaying)
        persistPosition(immediate: true)
    }

    func play(chapterAt index: Int) {
        guard let book, book.chapters.indices.contains(index) else { return }
        load(chapterIndex: index, startAt: 0, play: true)
        persistPosition(immediate: true)
    }

    // MARK: - Scrubbing

    func beginScrubbing() { isScrubbing = true }

    func scrub(to time: Double) {
        guard isScrubbing else { return }
        currentTime = min(max(0, time), max(0, duration))
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: currentTime)
    }

    // MARK: - Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepAtChapterEnd = false
        sleepTimerEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTicker?.invalidate()
        sleepTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSleepTimer() }
        }
    }

    func sleepAtEndOfChapter() {
        cancelSleepTimer()
        sleepAtChapterEnd = true
    }

    func cancelSleepTimer() {
        sleepTicker?.invalidate()
        sleepTicker = nil
        sleepTimerEndsAt = nil
        sleepAtChapterEnd = false
    }

    var sleepTimerRemaining: TimeInterval? {
        guard let end = sleepTimerEndsAt else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }

    private func checkSleepTimer() {
        guard let end = sleepTimerEndsAt else { return }
        if Date() >= end {
            cancelSleepTimer()
            if isPlaying { pause() }
        } else {
            // Republish so the player screen's countdown ticks.
            objectWillChange.send()
        }
    }

    // MARK: - Player observation

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // The observer is documented to call back on the queue it was given;
            // MainActor.assumeIsolated keeps that promise explicit.
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.currentTime = seconds

                // Trust the real asset once it is known: the imported duration
                // can be a rounded estimate.
                if let itemDuration = self.player.currentItem?.duration,
                   itemDuration.isNumeric {
                    let value = CMTimeGetSeconds(itemDuration)
                    if value.isFinite, value > 0, abs(value - self.duration) > 1 {
                        self.duration = value
                    }
                }
                if Date().timeIntervalSince(self.lastPersist) > 5 {
                    self.persistPosition(immediate: false)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem
                else { return }
                self.chapterDidEnd()
            }
        }
    }

    /// Autoplay: roll straight into the next chapter, unless the sleep timer
    /// was set to stop here or this was the last chapter.
    private func chapterDidEnd() {
        currentTime = duration
        persistPosition(immediate: true)

        if sleepAtChapterEnd {
            cancelSleepTimer()
            pause()
            if hasNextChapter { load(chapterIndex: chapterIndex + 1, startAt: 0, play: false) }
            return
        }

        guard hasNextChapter else {
            isPlaying = false
            player.pause()
            if let book { library.markFinished(bookID: book.id) }
            updateNowPlaying()
            return
        }
        load(chapterIndex: chapterIndex + 1, startAt: 0, play: true)
    }

    private func persistPosition(immediate: Bool) {
        guard let book else { return }
        lastPersist = Date()
        library.updateProgress(
            bookID: book.id,
            chapterIndex: chapterIndex,
            position: currentTime,
            immediate: immediate
        )
        // Keep the engine's own copy in step so the mini player's remaining
        // time matches the library row's.
        self.book?.chapterIndex = chapterIndex
        self.book?.position = currentTime
    }

    // MARK: - Audio session, interruptions, lifecycle

    private func configureAudioSession() {
        // .spokenAudio + .longFormAudio is what marks this as an audiobook: it
        // ducks correctly for navigation and hands the right controls to CarPlay.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, policy: .longFormAudio
        )
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeSystem() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                switch type {
                case .began:
                    if self.isPlaying { self.pause() }
                default:
                    // Resume only when the system says the interruption ended
                    // in a way that invites it - a phone call, not Siri talking.
                    let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                    if let options, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.play()
                    }
                }
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                // Headphones pulled out: never start playing out loud.
                if self.isPlaying { self.pause() }
            }
        }

        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.persistPosition(immediate: true)
                }
            }
        }
    }

    // MARK: - Lock screen and Control Center

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }

        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commands.skipForwardCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
                self?.skip(by: interval)
            }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
                self?.skip(by: -interval)
            }
            return .success
        }

        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.nextChapter() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previousChapter() }
            return .success
        }

        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }

        commands.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackRate.all.map { NSNumber(value: $0) }
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.rate = event.playbackRate }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let book, let chapter else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPMediaItemPropertyArtist: book.author,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPMediaItemPropertyAlbumTrackNumber: chapterIndex + 1,
            MPMediaItemPropertyAlbumTrackCount: book.chapters.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork = artwork(for: book) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func artwork(for book: Book) -> MPMediaItemArtwork? {
        if let cached = artworkCache, cached.bookID == book.id { return cached.artwork }
        guard let url = library.coverURL(for: book),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkCache = (book.id, artwork)
        return artwork
    }
}

enum PlaybackRate {
    static let all: [Float] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    static func label(_ rate: Float) -> String {
        // 1.0x, 1.25x - no trailing zeros beyond what the value needs.
        let text = String(format: "%.2f", rate)
        var trimmed = text
        while trimmed.hasSuffix("0"), !trimmed.hasSuffix(".0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".0") { trimmed.removeLast(2); trimmed += ".0" }
        return trimmed.replacingOccurrences(of: ".", with: ",") + "×"
    }
}

private extension UserDefaults {
    var playbackRate: Float {
        get {
            let stored = float(forKey: "playbackRate")
            return stored > 0 ? stored : 1.0
        }
        set { set(newValue, forKey: "playbackRate") }
    }

    var skipInterval: Double {
        get {
            let stored = double(forKey: "skipInterval")
            return stored > 0 ? stored : 30
        }
        set { set(newValue, forKey: "skipInterval") }
    }
}
