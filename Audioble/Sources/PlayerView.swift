import AVKit
import GoogleCast
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var cast = CastManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showChapters = false
    @State private var showSpeed = false
    @State private var showSleepTimer = false

    var body: some View {
        ZStack {
            backdrop
            if let book = player.book {
                content(book: book)
            } else {
                Text("Kein Buch geöffnet").foregroundStyle(Theme.secondaryText)
            }
        }
        .sheet(isPresented: $showChapters) { ChapterListSheet() }
        .sheet(isPresented: $showSpeed) { SpeedSheet() }
        .sheet(isPresented: $showSleepTimer) { SleepTimerSheet() }
        .statusBarHidden(false)
        // The Cast context has to exist before GCKUICastButton is created.
        .onAppear { CastManager.shared.startIfNeeded() }
    }

    /// Teal at the top fading into the app's near-black, tinted by the cover -
    /// the gradient from the reference player screen.
    private var backdrop: some View {
        let tint = player.book.map { CoverCache.shared.tint(for: $0) } ?? Theme.playerTopFallback
        return LinearGradient(
            stops: [
                .init(color: tint, location: 0),
                .init(color: tint.opacity(0.45), location: 0.22),
                .init(color: Theme.background, location: 0.58),
                .init(color: Theme.background, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func content(book: Book) -> some View {
        VStack(spacing: 0) {
            topBar(book: book)

            Spacer(minLength: 8)

            CoverImage(book: book, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 330)
                .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                .padding(.horizontal, 36)

            Spacer(minLength: 12)

            VStack(spacing: 3) {
                Text(book.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(book.author)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                if cast.isConnected, let device = cast.deviceName {
                    HStack(spacing: 5) {
                        Image(systemName: "tv.badge.wifi").font(.system(size: 11))
                        Text("Auf \(device)").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 3)
                }
            }
            .padding(.horizontal, 30)

            Spacer(minLength: 12)

            chapterButton

            Spacer(minLength: 10)

            scrubberBlock

            Spacer(minLength: 6)

            transport

            Spacer(minLength: 10)

            bottomActions
                .padding(.bottom, 8)
        }
        .padding(.top, 6)
    }

    // MARK: - Top bar

    private func topBar(book: Book) -> some View {
        HStack {
            CircleButton(systemName: "chevron.down") { dismiss() }
            Spacer()
            CastButton()
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.28)))
            AirPlayButton()
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.28)))
            Menu {
                Button("Kapitelübersicht", systemImage: "list.bullet") { showChapters = true }
                Button("Wiedergabetempo", systemImage: "speedometer") { showSpeed = true }
                Button("Schlummer-Timer", systemImage: "moon.zzz") { showSleepTimer = true }
                Divider()
                Button("Von vorn beginnen", systemImage: "gobackward") {
                    library.resetProgress(bookID: book.id)
                    if let refreshed = library.book(id: book.id) {
                        player.open(refreshed, autoPlay: false)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.28)))
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Chapter

    private var chapterButton: some View {
        Button { showChapters = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 17, weight: .medium))
                Text(player.chapter?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scrubber

    private var scrubberBlock: some View {
        VStack(spacing: 6) {
            Scrubber(
                value: player.currentTime,
                total: player.duration,
                onBegin: { player.beginScrubbing() },
                onChange: { player.scrub(to: $0) },
                onEnd: { player.endScrubbing() }
            )

            HStack {
                Text(player.currentTime.asClock)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(max(0, player.duration - player.currentTime).asDurationWords) verbleibend")
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("- \(max(0, player.duration - player.currentTime).asClock)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack {
            TransportButton(systemName: "backward.end.fill", size: 25) {
                player.previousChapter()
            }
            .disabled(!player.hasPreviousChapter && player.currentTime <= 5)

            Spacer()

            Button { player.skip(by: -player.skipInterval) } label: {
                SkipGlyph(seconds: Int(player.skipInterval), forward: false, size: 33)
                    .foregroundStyle(Theme.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.white)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Theme.background)
                        .offset(x: player.isPlaying ? 0 : 3)
                }
                .frame(width: 86, height: 86)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { player.skip(by: player.skipInterval) } label: {
                SkipGlyph(seconds: Int(player.skipInterval), forward: true, size: 33)
                    .foregroundStyle(Theme.primaryText)
            }
            .buttonStyle(.plain)

            Spacer()

            TransportButton(systemName: "forward.end.fill", size: 25) {
                player.nextChapter()
            }
            .disabled(!player.hasNextChapter)
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Bottom row

    private var bottomActions: some View {
        HStack(alignment: .top, spacing: 0) {
            BottomAction(
                title: "Geschwindigkeit",
                label: .text(PlaybackRate.label(player.rate))
            ) { showSpeed = true }

            BottomAction(
                title: "Timer",
                label: .icon("timer"),
                isActive: player.sleepTimerEndsAt != nil || player.sleepAtChapterEnd,
                badge: sleepBadge
            ) { showSleepTimer = true }
        }
        .padding(.horizontal, 40)
    }

    private var sleepBadge: String? {
        if player.sleepAtChapterEnd { return "Kap." }
        guard let remaining = player.sleepTimerRemaining else { return nil }
        return "\(Int(remaining / 60) + 1)m"
    }

}

// MARK: - Small pieces

private struct CircleButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.28)))
        }
        .buttonStyle(.plain)
    }
}

private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .opacity(0.95)
    }
}

private struct BottomAction: View {
    enum Label { case icon(String), text(String) }

    let title: String
    let label: Label
    var isActive: Bool = false
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    switch label {
                    case .icon(let name):
                        Image(systemName: name)
                            .font(.system(size: 22, weight: .regular))
                            .frame(height: 26)
                    case .text(let value):
                        Text(value)
                            .font(.system(size: 20, weight: .bold))
                            .frame(height: 26)
                    }
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 16, y: -4)
                    }
                }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.primaryText)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Cast SDK's own button: it hides itself when no receiver is on the
/// network and presents the standard device picker when tapped.
private struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton()
        button.tintColor = .white
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

/// The system AirPlay picker, so playback can be sent to a HomePod or a car.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
