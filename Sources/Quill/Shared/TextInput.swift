import Foundation

/// Spelling and typing aids, as in iA Writer's Editor settings. Each app shows the ones its
/// text system has: grammar and text replacement are Mac only.
struct TextInput: Codable, Equatable {
    var checkSpelling = true
    var checkGrammar = false
    // Markdown wants straight quotes and plain hyphens, and on the Mac a word changing under
    // you is a surprise; the iPhone keyboard expects to correct and predict.
    #if os(macOS)
    var correctSpelling = false
    var predictive = false
    var smartCopyPaste = true
    #else
    var correctSpelling = true
    var predictive = true
    var smartCopyPaste = false
    #endif
    var smartQuotes = false
    var smartDashes = false
    var textReplacement = false

    typealias Group = [WritableKeyPath<TextInput, Bool>]

    /// The spelling options this app shows, in its menu's order.
    static var spelling: Group {
        #if os(macOS)
        var keys: Group = [\.checkSpelling, \.checkGrammar, \.correctSpelling]
        if #available(macOS 14.0, *) { keys.append(\.predictive) }
        return keys
        #else
        return [\.correctSpelling, \.checkSpelling, \.predictive]
        #endif
    }

    /// The substitution options this app shows.
    static var substitutions: Group {
        #if os(macOS)
        return [\.smartCopyPaste, \.smartQuotes, \.smartDashes, \.textReplacement]
        #else
        return [\.smartCopyPaste, \.smartQuotes, \.smartDashes]
        #endif
    }

    func allOn(_ group: Group) -> Bool { group.allSatisfy { self[keyPath: $0] } }

    /// Check All, or Uncheck All once they're all on.
    mutating func toggleAll(_ group: Group) {
        let on = !allOn(group)
        for key in group { self[keyPath: key] = on }
    }

    static func load(_ defaults: UserDefaults) -> TextInput {
        defaults.data(forKey: "textInput").flatMap { try? JSONDecoder().decode(TextInput.self, from: $0) } ?? TextInput()
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: "textInput")
    }
}
