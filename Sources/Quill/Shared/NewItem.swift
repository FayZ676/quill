import Foundation

/// A document or folder about to be made: the New sheet asks for its name, and where it goes.
struct NewItem: Identifiable {
    let id = UUID()
    let isFolder: Bool
    /// The folder it goes in, to begin with.
    let dir: URL

    var placeholder: String { isFolder ? "New Folder" : "Untitled" }

    /// The file name for what was typed: the placeholder for nothing, a dash for each slash
    /// (which would make folders), and a document's Markdown extension unless a text one is typed.
    func fileName(_ typed: String) -> (base: String, ext: String?) {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = placeholder }
        guard !isFolder else { return (name, nil) }
        let ext = (name as NSString).pathExtension.lowercased()
        if FileNode.textExtensions.contains(ext) { return ((name as NSString).deletingPathExtension, ext) }
        return (name, "md")
    }
}
