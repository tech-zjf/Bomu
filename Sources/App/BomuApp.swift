import SwiftUI

@main
struct BomuApp: App {
    var body: some Scene {
        Window(Brand.displayName, id: "main") {
            StartView()
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
    }
}
