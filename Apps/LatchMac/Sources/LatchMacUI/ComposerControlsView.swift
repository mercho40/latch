import AppKit

/// Keeps native controls comfortably sized, wrapping instead of squeezing their hit targets.
@MainActor
final class ComposerControlsView: NSView {
    /// A picker and the width it is allowed to take. Stated per control rather than by
    /// position, so adding one to the row cannot silently resize the others.
    struct Slot {
        let button: NSPopUpButton
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat

        /// A picker is as wide as its title by default; a minimum only made short titles look lost.
        init(_ button: NSPopUpButton, minimumWidth: CGFloat = 0, maximumWidth: CGFloat = 220) {
            self.button = button
            self.minimumWidth = minimumWidth
            self.maximumWidth = maximumWidth
        }
    }

    static let controlHeight: CGFloat = 36
    private let pickers: [Slot]
    private let actions: [NSButton]
    private let gap: CGFloat = 6
    private var surfaces: [ObjectIdentifier: NSView] = [:]
    /// The surface's padding around the pop-up it sits behind.
    private static let surfaceLeading: CGFloat = 5
    private static let surfaceTrailing: CGFloat = 12

    init(pickers: [Slot], actions: [NSButton]) {
        self.pickers = pickers
        self.actions = actions
        super.init(frame: .zero)
        if #available(macOS 26.0, *) {
            // Behind each picker, not around it: the pop-up stays a direct subview with a frame of
            // its own, and the surface is decoration that a click passes through to it.
            for slot in pickers {
                let glass = NSGlassEffectView()
                glass.cornerRadius = Self.controlHeight / 2
                surfaces[ObjectIdentifier(slot.button)] = glass
                addSubview(glass)
            }
        }
        for control in pickers.map(\.button) as [NSView] + actions { addSubview(control) }
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var isFlipped: Bool { true }

    /// How many pickers the composer carries, for the smoke run's bounds check.
    var pickerCount: Int { pickers.count }

    func refreshLayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { refreshLayout() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: placements(width: bounds.width).height)
    }

    override func layout() {
        super.layout()
        for (control, frame) in placements(width: bounds.width).items { control.frame = frame }
        for slot in pickers {
            guard let surface = surfaces[ObjectIdentifier(slot.button)] else { continue }
            surface.isHidden = slot.button.isHidden
            surface.frame = NSRect(x: slot.button.frame.minX - Self.surfaceLeading, y: slot.button.frame.minY,
                                   width: slot.button.frame.width + Self.surfaceLeading + Self.surfaceTrailing,
                                   height: slot.button.frame.height)
        }
    }

    /// The capsule is the control as far as anyone clicking it is concerned, padding included.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for slot in pickers where !slot.button.isHidden && slot.button.isEnabled {
            if surfaces[ObjectIdentifier(slot.button)]?.frame.contains(point) == true {
                slot.button.performClick(nil)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return surfaces.values.contains { $0 === hit } ? self : hit
    }

    /// A pop-up's intrinsic width is that of its longest item, which left "Opus 5" adrift in the
    /// space "Claude Sonnet 4.5 (1M context)" would need. It takes the width of what it shows.
    private static func fittedWidth(of button: NSPopUpButton) -> CGFloat {
        let title = (button.titleOfSelectedItem ?? button.title) as NSString
        let font = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        // Room for the arrows, and for a capsule's rounded ends where there is a bezel.
        // The title, a gap, and either our one chevron or the system's pair of arrows.
        let ownChevron = (button.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow
        return ceil(title.size(withAttributes: [.font: font]).width) + (ownChevron ? 26 : 30)
    }

    private func placements(width: CGFloat) -> (items: [(NSView, NSRect)], height: CGFloat) {
        // Before Auto Layout assigns a width, report the wide, single-row size.
        let width = width > 0 ? width : 768
        var items: [(NSView, NSRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for slot in pickers where !slot.button.isHidden {
            let padding = surfaces.isEmpty ? 0 : Self.surfaceLeading + Self.surfaceTrailing
            let size = min(width, max(slot.minimumWidth, min(slot.maximumWidth, Self.fittedWidth(of: slot.button) + padding)))
            if x > 0 && x + size > width { x = 0; y += Self.controlHeight + gap }
            let leading = surfaces.isEmpty ? 0 : Self.surfaceLeading
            items.append((slot.button, NSRect(x: x + leading, y: y, width: size - padding, height: Self.controlHeight)))
            x += size + gap
        }
        let visibleActions = actions.filter { !$0.isHidden }
        if !visibleActions.isEmpty {
            let actionWidth = CGFloat(visibleActions.count) * Self.controlHeight + CGFloat(visibleActions.count - 1) * gap
            if x > 0 && x + actionWidth > width { y += Self.controlHeight + gap }
            var actionX = max(0, width - actionWidth)
            for action in visibleActions {
                items.append((action, NSRect(x: actionX, y: y, width: Self.controlHeight, height: Self.controlHeight)))
                actionX += Self.controlHeight + gap
            }
        }
        return (items, y + Self.controlHeight)
    }
}
