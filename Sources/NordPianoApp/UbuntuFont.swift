import AppKit

/// Bundles the Ubuntu font (Ubuntu Font License, see Fonts/) and makes it the
/// app-wide default by swizzling NSFont.systemFont — every SwiftUI `.system`
/// font resolves to the matching Ubuntu weight.
enum UbuntuFont {
    nonisolated(unsafe) static var regular: NSFont?
    nonisolated(unsafe) static var medium: NSFont?
    nonisolated(unsafe) static var bold: NSFont?
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        // Register the bundled TTFs from the app bundle's Resources folder.
        // (No-op when running from swift build without a bundle — fonts just stay absent.)
        let names = ["Ubuntu-Regular", "Ubuntu-Medium", "Ubuntu-Bold"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        regular = NSFont(name: "Ubuntu", size: 13)
        medium = NSFont(name: "Ubuntu Medium", size: 13)
        bold = NSFont(name: "Ubuntu-Bold", size: 13)
        guard regular != nil else { return }

        let meta = object_getClass(NSFont.self)!
        swap(meta, #selector(NSFont.systemFont(ofSize:)), #selector(NSFont.ubuntuSystemFont(ofSize:)))
        swap(meta, #selector(NSFont.boldSystemFont(ofSize:)), #selector(NSFont.ubuntuBoldSystemFont(ofSize:)))
        swap(meta, #selector(NSFont.systemFont(ofSize:weight:)), #selector(NSFont.ubuntuSystemFont(ofSize:weight:)))
    }

    private static func swap(_ meta: AnyClass, _ a: Selector, _ b: Selector) {
        guard let mA = class_getClassMethod(meta, a), let mB = class_getClassMethod(meta, b) else { return }
        method_exchangeImplementations(mA, mB)
    }
}

extension NSFont {
    // After the exchange, calling the system selectors inside these runs the
    // original Apple implementations (standard swizzle pattern).
    @objc static func ubuntuSystemFont(ofSize size: CGFloat) -> NSFont {
        guard let base = UbuntuFont.regular else { return NSFont.systemFont(ofSize: size) }
        return base.withSize(size)
    }

    @objc static func ubuntuBoldSystemFont(ofSize size: CGFloat) -> NSFont {
        guard let base = UbuntuFont.bold ?? UbuntuFont.regular else { return NSFont.boldSystemFont(ofSize: size) }
        return base.withSize(size)
    }

    @objc static func ubuntuSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base: NSFont?
        switch weight {
        case let w where w >= .bold: base = UbuntuFont.bold ?? UbuntuFont.regular
        case let w where w >= .semibold: base = UbuntuFont.medium ?? UbuntuFont.regular
        default: base = UbuntuFont.regular
        }
        guard let base else { return NSFont.systemFont(ofSize: size, weight: weight) }
        return base.withSize(size)
    }
}
