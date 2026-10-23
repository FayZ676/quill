import UIKit

enum Theme {
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: white, green: white, blue: white, alpha: alpha)
    }

    static let background = dynamic(light: UIColor(red: 0.973, green: 0.973, blue: 0.965, alpha: 1),
                                     dark: UIColor(red: 0.102, green: 0.106, blue: 0.110, alpha: 1))
    static let text = dynamic(light: gray(0.15), dark: gray(0.86))
    static let markup = dynamic(light: gray(0.66), dark: gray(0.42))
    /// A `[[link]]`'s text, in the accent as Obsidian draws links; fainter for a note not
    /// written yet.
    static let link = accent
    static let unwritten = accent.withAlphaComponent(0.55)
    static let dimmed = dynamic(light: gray(0.80), dark: gray(0.30))
    static let codeBackground = dynamic(light: gray(0, 0.045), dark: gray(1, 0.06))
    /// The app accent (vermilion), defined once as AccentColor in Resources/Assets.xcassets.
    /// UIKit tints the caret and selection with it.
    static let accent = UIColor(named: "AccentColor") ?? UIColor(red: 0.949, green: 0.416, blue: 0.169, alpha: 1)
}
