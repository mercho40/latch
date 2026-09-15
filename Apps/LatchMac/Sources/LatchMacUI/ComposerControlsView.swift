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

        init(_ button: NSPopUpButton, minimumWidth: CGFloat = 140, maximumWidth: CGFloat = 220) {
            self.button = button
            self.minimumWidth = minimumWidth
            self.maximumWidth = maximumWidth
        }
    }

    static let controlHeight: CGFloat = 36
    private let pickers: [Slot]
    private let actions: [NSButton]
    private let gap: CGFloat = 8

    init(pickers: [Slot], actions: [NSButton]) {
        self.pickers = pickers
        self.actions = actions
        super.init(frame: .zero)
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
    }

    private func placements(width: CGFloat) -> (items: [(NSView, NSRect)], height: CGFloat) {
        // Before Auto Layout assigns a width, report the wide, single-row size.
        let width = width > 0 ? width : 768
        var items: [(NSView, NSRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for slot in pickers where !slot.button.isHidden {
            let size = min(width, max(slot.minimumWidth,
                                      min(slot.maximumWidth, slot.button.intrinsicContentSize.width + 8)))
            if x > 0 && x + size > width { x = 0; y += Self.controlHeight + gap }
            items.append((slot.button, NSRect(x: x, y: y, width: size, height: Self.controlHeight)))
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
