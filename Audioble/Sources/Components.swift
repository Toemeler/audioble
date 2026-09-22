import SwiftUI
import UIKit

/// Cover art is small (a few tens of kilobytes) but drawn in every row, so it
/// is decoded once and kept, together with the colour the player tints its
/// backdrop with.
@MainActor
final class CoverCache {
    static let shared = CoverCache()

    private let images = NSCache<NSString, UIImage>()
    private var tints: [UUID: Color] = [:]

    private init() { images.countLimit = 120 }

    func image(for book: Book) -> UIImage? {
        let key = book.id.uuidString as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let url = LibraryStore.shared.coverURL(for: book),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// The average colour of the cover's top half - what the player screen
    /// fades from, the way the reference screenshot picks up the artwork.
    func tint(for book: Book) -> Color {
        if let cached = tints[book.id] { return cached }
        guard let image = image(for: book), let cgImage = image.cgImage else {
            return Theme.playerTopFallback
        }
        let width = cgImage.width
        let height = max(1, cgImage.height / 2)
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let top = cgImage.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return Theme.playerTopFallback
        }
        context.draw(top, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return Theme.playerTopFallback }
        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        let colour = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Push it towards the deep, slightly desaturated tone the design uses,
        // so a pale or a garish cover still gives a usable backdrop.
        let tint = Color(UIColor(
            hue: hue,
            saturation: min(max(saturation, 0.35), 0.7),
            brightness: min(max(brightness, 0.45), 0.72),
            alpha: 1
        ))
        tints[book.id] = tint
        return tint
    }

    func forget(_ bookID: UUID) {
        images.removeObject(forKey: bookID.uuidString as NSString)
        tints[bookID] = nil
    }
}

/// Cover art with the placeholder used when a book carries none.
struct CoverImage: View {
    let book: Book
    var cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = CoverCache.shared.image(for: book) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Theme.playerTopFallback.opacity(0.7), Theme.surface],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        Image(systemName: "headphones")
                            .font(.system(size: geometry.size.width * 0.3, weight: .light))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// The thin orange "how far in" bar under a library row.
struct ProgressTrack: View {
    let progress: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, min(1, progress)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// The scrubber on the player screen: an orange track with a draggable thumb
/// that keeps the displayed time under the finger while dragging.
struct Scrubber: View {
    let value: Double
    let total: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: fraction * width, height: 4)
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: 13, height: 13)
                    .offset(x: fraction * width - 6.5)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onBegin()
                        guard width > 0, total > 0 else { return }
                        onChange(min(max(0, gesture.location.x / width), 1) * total)
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 28)
    }
}

/// An outlined pill, as used for the library's filter row.
struct FilterChip: View {
    let title: String
    var systemImage: String?
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(isOn ? Theme.background : Theme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(isOn ? Theme.primaryText : Color.clear)
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.chipBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

/// Round outlined play/pause button on a library row.
struct RowPlayButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Theme.secondaryText.opacity(0.65), lineWidth: 1.5)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
    }
}
