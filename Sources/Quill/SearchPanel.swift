import SwiftUI

/// A box to type in over the list it narrows, as Obsidian's quick switcher is: Go To, choosing
/// a folder, the cheat sheet. The arrow keys move through the matches, Return takes the one
/// picked, Escape closes.
struct SearchPanel<Item: Identifiable, Row: View>: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String
    let empty: String
    let height: CGFloat
    /// The items that hold what's typed, in order.
    let matches: (String) -> [Item]
    /// The heading of the group an item is in, for a list in groups.
    let section: (Item) -> String?
    /// What Return or a click does with an item; nothing, for a list only to read.
    let pick: ((Item) -> Void)?
    let row: (Item) -> Row
    @State private var query = ""
    @State private var picked = 0
    @State private var keys: Any?
    @FocusState private var typing: Bool

    init(prompt: String, empty: String = "Nothing Matches", height: CGFloat = 360,
         matches: @escaping (String) -> [Item], section: @escaping (Item) -> String? = { _ in nil },
         pick: ((Item) -> Void)? = nil, @ViewBuilder row: @escaping (Item) -> Row) {
        self.prompt = prompt
        self.empty = empty
        self.height = height
        self.matches = matches
        self.section = section
        self.pick = pick
        self.row = row
    }

    var body: some View {
        let found = matches(query)
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .appFont(16)
                .focused($typing)
                .onSubmit { if found.indices.contains(picked) { choose(found[picked]) } }
                .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(found.enumerated()), id: \.element.id) { i, item in
                            if let title = section(item), i == 0 || section(found[i - 1]) != title {
                                Text(title)
                                    .appFont(11, bold: true)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 10)
                                    .padding(.top, i == 0 ? 6 : 14)
                                    .padding(.bottom, 4)
                            }
                            Button {
                                picked = i
                                choose(item)
                            } label: {
                                row(item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(i == picked ? Color.secondary.opacity(0.18) : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                // By id: an index as a row's id leaves the rows showing what they matched
                // before, when the query narrows them.
                .onChange(of: picked) { if found.indices.contains($0) { proxy.scrollTo(found[$0].id) } }
            }
            .overlay {
                if found.isEmpty {
                    Text(empty).appFont(14).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 480, height: height)
        .background(Color(nsColor: Theme.background))
        .onChange(of: query) { _ in picked = 0 }
        .onAppear {
            typing = true
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: picked = min(picked + 1, max(matches(query).count - 1, 0))
                case 126: picked = max(picked - 1, 0)
                case 53: dismiss()
                default: return event
                }
                return nil
            }
        }
        .onDisappear { keys.map(NSEvent.removeMonitor) }
    }

    private func choose(_ item: Item) {
        guard let pick else { return }
        dismiss()
        pick(item)
    }
}
