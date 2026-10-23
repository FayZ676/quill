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
                // All of Quill's own text in the chosen font, not just the page. The font
                // goes inside the choice, so it reads the choice rather than the default.
                .appFont(17, relativeTo: .body)
                .environment(\.editorFont, state.editorFont)
                .tint(Color(uiColor: Theme.accent))
                // The window exists by now, so the saved appearance can reach it.
                .onAppear { state.appearance.apply() }
        }
    }
}
