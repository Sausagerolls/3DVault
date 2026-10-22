import SwiftUI

/// Light, dark or follow the system. Stored per device.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
