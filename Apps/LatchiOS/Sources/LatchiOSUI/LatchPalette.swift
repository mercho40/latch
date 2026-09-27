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

    /// Behind the user's own messages: a soft tone of the tint, so a prompt reads as the
    /// user's without the weight of a filled bubble, and body text keeps its contrast on it.
    static let userBubble = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        let highContrast = traits.accessibilityContrast == .high
        return tint.resolvedColor(with: traits).withAlphaComponent(dark ? (highContrast ? 0.42 : 0.30) : (highContrast ? 0.22 : 0.13))
    }

    /// The panel behind a code block, a table's header and the tool details: one step off the
    /// page in either appearance.
    static let codeBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : UIColor(white: 0, alpha: 0.04)
    }

    /// Behind inline `code`: a little stronger than a block, because it is a few characters wide.
    static let inlineCode = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.07)
    }
}
