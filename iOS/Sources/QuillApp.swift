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
                // All of Quill's own text in the chosen font, not just the page.
                .environment(\.editorFont, state.editorFont)
                .appFont(17, relativeTo: .body)
                .tint(Color(uiColor: Theme.accent))
        }
    }
}
