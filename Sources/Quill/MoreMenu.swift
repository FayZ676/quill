import AppKit
import SwiftUI

/// The ⋯ menu in Quill's bar: writing options and the open file's actions, as in the iPhone
/// editor's ⋯ menu. Built in AppKit for its section headings.
enum MoreMenu {
    static func make(_ state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("Focus"))
        menu.addItem(ActionItem("Focus Mode", on: state.focusEnabled) { state.focusEnabled.toggle() })
        menu.addItem(submenu("Focus On", FocusStyle.allCases.map { style in
            ActionItem(style.rawValue, on: state.focusStyle == style) { state.focusStyle = style }
        }))
        menu.addItem(ActionItem("Typewriter Scrolling", on: state.typewriter) { state.typewriter.toggle() })

        menu.addItem(.separator())
        menu.addItem(header("Font"))
        menu.addItem(submenu("Typeface", EditorFont.allCases.map { font in
            ActionItem(font.rawValue, on: state.editorFont == font) { state.editorFont = font }
        }))
        menu.addItem(ActionItem("Smaller") { state.fontSize = max(11, state.fontSize - 1) })
        menu.addItem(ActionItem("Bigger") { state.fontSize = min(32, state.fontSize + 1) })

        menu.addItem(.separator())
        menu.addItem(header("Spelling and Grammar"))
        menu.addItem(toggle("Check Spelling While Typing", \.checkSpelling, state))
        menu.addItem(toggle("Check Grammar With Spelling", \.checkGrammar, state))
        menu.addItem(toggle("Correct Spelling Automatically", \.correctSpelling, state))
        if #available(macOS 14.0, *) {
            menu.addItem(toggle("Show Inline Predictive Text", \.predictive, state))
        }
        menu.addItem(toggleAll(TextInput.spelling, state))

        menu.addItem(.separator())
        menu.addItem(header("Substitutions"))
        menu.addItem(toggle("Smart Copy/Paste", \.smartCopyPaste, state))
        menu.addItem(toggle("Smart Quotes", \.smartQuotes, state))
        menu.addItem(toggle("Smart Dashes", \.smartDashes, state))
        menu.addItem(toggle("Text Replacement", \.textReplacement, state))
        menu.addItem(toggleAll(TextInput.substitutions, state))

        if let file = state.openFile {
            menu.addItem(.separator())
            menu.addItem(header("File"))
            menu.addItem(ActionItem("Rename…") { state.beginRename(file) })
            menu.addItem(submenu("Move To", state.moveTargets(for: file).map { folder in
                ActionItem(String(repeating: "    ", count: max(0, folder.depth - 1))
                           + folder.url.lastPathComponent) { state.move(file, into: folder.url) }
            }))
            menu.addItem(NSSharingServicePicker(items: [file]).standardShareMenuItem)
            menu.addItem(ActionItem("Reveal in Finder") { state.reveal(file) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Move to Trash") { state.trash(file) })
        }
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        items.forEach(item.submenu!.addItem)
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func toggleAll(_ group: TextInput.Group, _ state: AppState) -> NSMenuItem {
        ActionItem(state.textInput.allOn(group) ? "Uncheck All" : "Check All") { state.textInput.toggleAll(group) }
    }

    private static func toggle(_ title: String, _ key: WritableKeyPath<TextInput, Bool>, _ state: AppState) -> NSMenuItem {
        ActionItem(title, on: state.textInput[keyPath: key]) { state.textInput[keyPath: key].toggle() }
    }
}

/// The sidebar's + menu, as in the iPhone library's.
enum NewMenu {
    static func make(_ state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("New File", symbol: "square.and.pencil") { state.newFile() })
        menu.addItem(ActionItem("New Folder", symbol: "folder.badge.plus") { state.newFolder() })
        return menu
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool = false, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = on ? .on : .off
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Holds the AppKit view behind a SwiftUI control, so a menu can drop down from it.
final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
