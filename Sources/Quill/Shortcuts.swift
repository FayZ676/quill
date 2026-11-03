import SwiftUI

/// A key and its modifiers, as the menus take it and as the cheat sheet writes it out.
struct Shortcut {
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command

    /// As the menus show it, like ⇧⌘O.
    var label: String {
        let glyphs: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let names: [Character: String] = [KeyEquivalent.delete.character: "⌫"]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined()
            + (names[key.character] ?? String(key.character).uppercased())
    }
}

/// Every shortcut of Quill's own, for the menus to set and the cheat sheet to list, so the two
/// can't drift apart.
enum Shortcuts {
    static let newFile = Shortcut(key: "n")
    static let newFolder = Shortcut(key: "n", modifiers: [.command, .shift])
    static let goTo = Shortcut(key: "o", modifiers: [.command, .shift])
    static let openFolder = Shortcut(key: "o")
    static let save = Shortcut(key: "s")
    static let reveal = Shortcut(key: "r", modifiers: [.command, .option])
    static let trash = Shortcut(key: .delete, modifiers: [.command, .option])

    static let bold = Shortcut(key: "b")
    static let italic = Shortcut(key: "i")
    static let strikethrough = Shortcut(key: "x", modifiers: [.command, .shift])
    static let code = Shortcut(key: "c", modifiers: [.command, .shift])
    static let link = Shortcut(key: "k")

    static let back = Shortcut(key: "[")
    static let forward = Shortcut(key: "]")
    static let sidebar = Shortcut(key: "s", modifiers: [.control, .command])
    static let graph = Shortcut(key: "g", modifiers: [.option, .command])
    static let terminal = Shortcut(key: "`", modifiers: .control)
    static let focus = Shortcut(key: "d", modifiers: [.command, .shift])
    static let typewriter = Shortcut(key: "t", modifiers: [.command, .shift])
    static let bigger = Shortcut(key: "=")
    static let smaller = Shortcut(key: "-")
    static let actualSize = Shortcut(key: "0")

    static let cheatSheet = Shortcut(key: "/")
}

extension View {
    func keyboardShortcut(_ shortcut: Shortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
