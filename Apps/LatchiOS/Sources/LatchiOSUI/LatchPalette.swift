import UIKit

/// Latch's own colours on iOS. Everything else is a system colour, so it follows light and
/// dark, Increase Contrast and the accessibility settings without Latch doing anything.
enum LatchPalette {
    /// The blue of the icon's front rectangle, set as the window's tint. Light deepens it so
    /// tinted text such as a button's title keeps 4.5:1 against white; dark uses the icon's
    /// own blue, which clears that against black.
    static let tint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(displayP3Red: 0.040, green: 0.561, blue: 1, alpha: 1)
            : UIColor(displayP3Red: 0, green: 0.420, blue: 0.780, alpha: 1)
    }
}
