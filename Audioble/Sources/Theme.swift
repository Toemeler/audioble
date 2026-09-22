import SwiftUI

/// Colours sampled from the reference screenshots, so the app reads as one
/// piece with them rather than approximately like them.
enum Theme {
    static let background = Color(hex: 0x010E19)
    static let surface = Color(hex: 0x0B1826)
    static let separator = Color(hex: 0x16232F)

    static let primaryText = Color.white
    static let secondaryText = Color(hex: 0x8FA0B3)
    static let tertiaryText = Color(hex: 0x5E7085)

    /// Progress bars, the scrubber and anything that means "how far in you are".
    static let accent = Color(hex: 0xFFA000)
    static let accentBright = Color(hex: 0xFFB333)
    /// Unfilled scrubber track.
    static let track = Color(hex: 0x2B3640)
    /// Selected tab underline and tab-bar selection.
    static let tabAccent = Color(hex: 0x2D8FEA)
    static let chipBorder = Color(hex: 0x2E4257)

    /// Fallback player backdrop for a book with no cover art.
    static let playerTopFallback = Color(hex: 0x1B8DAF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Double {
    /// "4:53" under an hour, "1:04:53" above it - the player's clock format.
    var asClock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "14h 22min", "52min", "7s" - how the library and the player label what is left.
    var asDurationWords: String {
        guard isFinite, self >= 0 else { return "0s" }
        let total = Int(rounded())
        let (h, m) = (total / 3600, (total % 3600) / 60)
        if h > 0 { return m > 0 ? "\(h)h \(m)min" : "\(h)h" }
        if m > 0 { return "\(m)min" }
        return "\(total)s"
    }
}
