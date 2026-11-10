import SwiftUI
import AppKit

@main
struct NordPianoApp: App {
    @StateObject private var model = PlayerModel()

    init() {
        NSApplication.shared.applicationIconImage = makeAppIcon()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 440)
        }
        .windowResizability(.contentSize)
    }
}

/// Nord brand palette.
enum NordColor {
    static let red = Color(red: 0.855, green: 0.0, blue: 0.07)   // #DA0012
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let text = Color.white.opacity(0.92)
    static let subtext = Color.white.opacity(0.45)
}
