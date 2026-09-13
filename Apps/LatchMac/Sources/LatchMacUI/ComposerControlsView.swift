import AppKit

/// Keeps native controls comfortably sized, wrapping instead of squeezing their hit targets.
@MainActor
final class ComposerControlsView: NSView {
    static let controlHeight: CGFloat = 36
    private let pickers: [NSPopUpButton]
    private let actions: [NSButton]
    private let gap: CGFloat = 8

    init(pickers: [NSPopUpButton], actions: [NSButton]) {
        self.pickers = pickers
        self.actions = actions
        super.init(frame: .zero)
        for control in pickers + actions { addSubview(control) }
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var isFlipped: Bool { true }

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
        let width = width > 0 ? width : ChatTranscriptView.maximumContentWidth
        var items: [(NSView, NSRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for (index, picker) in pickers.enumerated() where !picker.isHidden {
            let maximum: CGFloat = index == 0 ? 260 : (index == 1 ? 150 : 220)
            let minimum: CGFloat = index == 1 ? 96 : 140
            let size = min(width, max(minimum, min(maximum, picker.intrinsicContentSize.width + 8)))
            if x > 0 && x + size > width { x = 0; y += Self.controlHeight + gap }
            items.append((picker, NSRect(x: x, y: y, width: size, height: Self.controlHeight)))
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
