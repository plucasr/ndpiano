import SwiftUI

/// App typeface helper. SwiftUI on macOS 14+ resolves `.system` fonts through
/// CoreText, bypassing the NSFont swizzle in UbuntuFont — so fonts must be set
/// explicitly. Fonts are registered at launch by `UbuntuFont.install()`.
enum NordFont {
    /// Ubuntu at `size` in the matching weight: ≥ bold → Ubuntu Bold,
    /// ≥ semibold → Ubuntu Medium, else regular.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Ubuntu-Bold"
        case .semibold, .medium: name = "Ubuntu Medium"
        default: name = "Ubuntu"
        }
        return .custom(name, size: size)
    }
}
