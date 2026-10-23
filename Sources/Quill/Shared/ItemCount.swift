import SwiftUI

/// A folder row's count, on its right: how many items the folder holds.
struct ItemCount: View {
    let count: Int?

    var body: some View {
        if let count {
            Text(count >= 10_000 ? count.formatted(.number.notation(.compactName)) : count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) item\(count == 1 ? "" : "s")")
        }
    }
}
