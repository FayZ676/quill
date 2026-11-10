import SwiftUI

/// A change Claude proposes to a file, over the page: what it takes out struck through, what it
/// puts in highlighted, and a few lines around each for context, with Reject and Accept above.
/// You can answer in the terminal instead, and this goes away.
struct ChangeReview: View {
    @EnvironmentObject var state: AppState
    let change: ProposedChange
    /// Changes waiting behind this one.
    let more: Int

    var body: some View {
        let fonts = FontSet(state.editorFont, size: CGFloat(state.fontSize))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if more > 0 { Text("\(more) more after this").foregroundStyle(.tertiary) }
                Spacer()
                Button("Reject") { ClaudeBridge.shared.reject(change) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .pointingHandCursor()
                    .help("Reject the Change")
                Button("Accept") { ClaudeBridge.shared.accept(change) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .pointingHandCursor()
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Accept the Change (⌘↩)")
            }
            .appFont(13)
            .padding(.horizontal, 16)
            .frame(height: 36)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.rows(from: change.old, to: change.new).enumerated()), id: \.offset) { _, row in
                        line(row, font: Font(fonts.regular))
                    }
                }
                .frame(maxWidth: fonts.width("0") * 68)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
        .background(Color(nsColor: Theme.background))
    }

    private var title: String {
        let name = FileNode.displayName(change.file)
        return change.old.isEmpty ? "Claude wants to create \(name)" : "Claude wants to change \(name)"
    }

    @ViewBuilder
    private func line(_ row: LineDiff.Row, font: Font) -> some View {
        switch row {
        case .same(let text):
            Text(text.isEmpty ? " " : text).font(font).foregroundStyle(Color(nsColor: Theme.markup))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        case .removed(let text):
            Text(text.isEmpty ? " " : text).font(font).strikethrough().foregroundStyle(Color(nsColor: Theme.text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.red.opacity(0.14))
        case .added(let text):
            Text(text.isEmpty ? " " : text).font(font).foregroundStyle(Color(nsColor: Theme.text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.green.opacity(0.16))
        case .skipped(let count):
            Text("\(count) unchanged \(count == 1 ? "line" : "lines")")
                .appFont(12)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
    }
}

/// The lines of one text against another's, with long runs that didn't change folded away.
enum LineDiff {
    enum Row: Equatable {
        case same(String), removed(String), added(String)
        /// Unchanged lines left out.
        case skipped(Int)
    }

    /// Lines kept around each change.
    static let context = 3

    static func rows(from old: String, to new: String) -> [Row] {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                rows.append(.removed(before[i])); i += 1
            } else if j < after.count, inserted.contains(j) {
                rows.append(.added(after[j])); j += 1
            } else {
                rows.append(.same(before[i])); i += 1; j += 1
            }
        }
        return fold(rows)
    }

    /// Keeps `context` unchanged lines either side of each change, and counts the rest.
    private static func fold(_ rows: [Row]) -> [Row] {
        let changed = rows.indices.filter { if case .same = rows[$0] { false } else { true } }
        guard !changed.isEmpty else { return rows }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(rows.count - 1, index + context)) }
        var folded: [Row] = []
        var run = 0
        for (index, row) in rows.enumerated() {
            if keep.contains(index) {
                if run > 0 { folded.append(.skipped(run)); run = 0 }
                folded.append(row)
            } else {
                run += 1
            }
        }
        if run > 0 { folded.append(.skipped(run)) }
        return folded
    }
}
