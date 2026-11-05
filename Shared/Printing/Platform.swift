import SwiftUI

// Small differences between iOS and macOS used by the shared printing views.

#if os(iOS)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

extension Color {
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let canvasBackground = Color(.secondarySystemBackground)
}

@MainActor func successHaptic() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
}
#else
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

extension Color {
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let canvasBackground = Color(nsColor: .underPageBackgroundColor)
}

@MainActor func successHaptic() {}
#endif

extension Color {
    /// "#RRGGBB", as printers and slicers write colours.
    var hexString: String {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #endif
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension View {
    /// Inline navigation titles on iOS; macOS has no equivalent.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
