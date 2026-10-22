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
