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
/// can't drift apart. Where VS Code has the same action, Quill takes its key, so muscle memory
/// carries over.
enum Shortcuts {
    static let newFile = Shortcut(key: "n")
    static let newFolder = Shortcut(key: "n", modifiers: [.command, .shift])
    static let goTo = Shortcut(key: "f", modifiers: [.command, .shift])
    static let openFolder = Shortcut(key: "o")
    static let save = Shortcut(key: "s")
    static let reveal = Shortcut(key: "r", modifiers: [.command, .option])
    static let trash = Shortcut(key: .delete, modifiers: [.command, .option])

    static let find = Shortcut(key: "f")
    static let replace = Shortcut(key: "f", modifiers: [.option, .command])
    static let findNext = Shortcut(key: "g")
    static let findPrevious = Shortcut(key: "g", modifiers: [.command, .shift])
    static let useSelection = Shortcut(key: "e")

    static let bold = Shortcut(key: "b", modifiers: [.command, .shift])
    static let italic = Shortcut(key: "i")
    static let strikethrough = Shortcut(key: "x", modifiers: [.command, .shift])
    static let code = Shortcut(key: "c", modifiers: [.command, .shift])
    static let link = Shortcut(key: "k")

    static let back = Shortcut(key: "-", modifiers: .control)
    static let forward = Shortcut(key: "-", modifiers: [.control, .shift])
    static let sidebar = Shortcut(key: "b")
    static let graph = Shortcut(key: "g", modifiers: [.option, .command])
    static let terminal = Shortcut(key: "`")
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
