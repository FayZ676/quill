import SwiftUI

/// The notes LinkSuggester offers, as a small floating list under the link being typed.
struct LinkSuggestionList: View {
    let items: [LinkSuggester.Item]
    let selected: Int
    let font: EditorFont
    let pick: (Int) -> Void

    private static let rowHeight: CGFloat = 26
    private static let inset: CGFloat = 4
    private static let cardWidth: CGFloat = 300
    /// Room around the card for its shadow.
    static let margin: CGFloat = 12

    /// The list's size for `count` notes, its shadow margin included.
    static func size(for count: Int) -> CGSize {
        CGSize(width: cardWidth + 2 * margin, height: CGFloat(count) * rowHeight + 2 * inset + 2 * margin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 12) {
                    Text(item.name)
                        .font(.quill(font, size: 13))
                        .foregroundStyle(Color(nsColor: Theme.text))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !item.folder.isEmpty {
                        Text(item.folder)
                            .font(.quill(font, size: 11))
                            .foregroundStyle(Color(nsColor: Theme.markup))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight)
                .background(i == selected ? Color(nsColor: Theme.accent).opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { pick(i) }
            }
        }
        .padding(Self.inset)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(Color(nsColor: Theme.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: Theme.markup).opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(Self.margin)
    }
}
