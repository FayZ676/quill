import SwiftUI

/// A box to type in over the list it narrows, as Obsidian's quick switcher is: Go To, choosing
/// a folder, the cheat sheet. The arrow keys move through the matches, Return takes the one
/// picked, Escape closes. Floats over the window with `searchPanel(isPresented:)`, or goes
/// in a sheet where it's opened from one.
struct SearchPanel<Item: Identifiable, Row: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeSearchPanel) private var closeFloating
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
                            .pointingHandCursor(pick != nil)
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
                case 53: close()
                default: return event
                }
                return nil
            }
        }
        .onDisappear { keys.map(NSEvent.removeMonitor) }
    }

    private func choose(_ item: Item) {
        guard let pick else { return }
        close()
        pick(item)
    }

    /// Floating over the window, or as a sheet, as it's shown.
    private func close() {
        if let closeFloating { closeFloating() } else { dismiss() }
    }
}

extension View {
    /// Floats a search panel in the middle of `area`, a frame in the window's (global)
    /// coordinates such as the page's, or of the whole window where it doesn't fit there. Escape
    /// or a click anywhere else in the window puts it away.
    func searchPanel<Panel: View>(isPresented: Binding<Bool>, over area: CGRect = .zero,
                                  @ViewBuilder panel: @escaping () -> Panel) -> some View {
        overlay {
            if isPresented.wrappedValue {
                GeometryReader { geometry in
                    let window = geometry.frame(in: .global)
                    ZStack {
                        // All but clear, so it still takes the click.
                        Color.black.opacity(0.001)
                            .onTapGesture { isPresented.wrappedValue = false }
                        CenteredIn(area: area.offsetBy(dx: -window.minX, dy: -window.minY)) {
                            panel()
                                .environment(\.closeSearchPanel) { isPresented.wrappedValue = false }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3)))
                                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// Puts its one view in the middle of `area`, given in its own coordinates, when the view fits
/// there with some room around it, as on a page with the terminal or sidebar open in a small
/// window; in the middle of all of it otherwise.
private struct CenteredIn: Layout {
    let area: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(.unspecified)
        let fits = area.width >= size.width + 40 && area.height >= size.height + 40
        let center = fits ? CGPoint(x: bounds.minX + area.midX, y: bounds.minY + area.midY)
                          : CGPoint(x: bounds.midX, y: bounds.midY)
        view.place(at: center, anchor: .center, proposal: ProposedViewSize(size))
    }
}

private struct CloseSearchPanelKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private extension EnvironmentValues {
    var closeSearchPanel: (() -> Void)? {
        get { self[CloseSearchPanelKey.self] }
        set { self[CloseSearchPanelKey.self] = newValue }
    }
}
