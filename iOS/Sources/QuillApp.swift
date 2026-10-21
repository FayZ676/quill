import SwiftUI

@main
struct QuillApp: App {
    @ObservedObject private var state = AppState.shared

    init() {
        Fonts.registerBundled()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .tint(Color(uiColor: Theme.accent))
        }
    }
}
