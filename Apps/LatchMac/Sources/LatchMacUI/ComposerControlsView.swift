import AppKit

/// Keeps native controls comfortably sized on one row. Pickers that do not fit fold, last first,
/// into a "More" menu at the row's end rather than wrapping the composer onto a second line.
@MainActor
final class ComposerControlsView: NSView, NSMenuDelegate {
    /// A picker and the width it is allowed to take. Stated per control rather than by
    /// position, so adding one to the row cannot silently resize the others.
    struct Slot {
        let button: NSPopUpButton
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat
        /// Whether it may fold into the More menu; the first picker never does, and shortens instead.
        let folds: Bool

        /// A picker is as wide as its title by default; a minimum only made short titles look lost.
        init(_ button: NSPopUpButton, minimumWidth: CGFloat = 0, maximumWidth: CGFloat = 220, folds: Bool = true) {
            self.button = button
            self.minimumWidth = minimumWidth
            self.maximumWidth = maximumWidth
            self.folds = folds
        }
    }

    static let controlHeight: CGFloat = 36
    private let pickers: [Slot]
    private let actions: [NSButton]
    /// A short note before the actions, such as how full the agent's context is. It shows only
    /// where it fits on their row, so it never costs the composer a line.
    private let accessory: NSTextField?
    /// The pickers that did not fit, as a pull-down whose menu is theirs.
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private var folded: [NSPopUpButton] = []
    private let gap: CGFloat = 6
    private var surfaces: [ObjectIdentifier: NSView] = [:]
    /// The surface's padding around the pop-up it sits behind.
    private static let surfaceLeading: CGFloat = 5
    private static let surfaceTrailing: CGFloat = 12
    /// The narrowest the first picker gets before it truncates no further.
    private static let shortestFirstPicker: CGFloat = 90

    init(pickers: [Slot], actions: [NSButton], accessory: NSTextField? = nil) {
        self.pickers = pickers
        self.actions = actions
        self.accessory = accessory
        super.init(frame: .zero)
        more.addItem(withTitle: "")
        more.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More options")
        more.imagePosition = .imageOnly
        more.isBordered = false
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.menu?.delegate = self
        more.menu?.autoenablesItems = false
        more.setAccessibilityLabel("More options")
        more.toolTip = "More options"
        more.isHidden = true
        if #available(macOS 26.0, *) {
            more.controlSize = .large
            // Behind each picker, not around it: the pop-up stays a direct subview with a frame of
            // its own, and the surface is decoration that a click passes through to it.
            for button in pickers.map(\.button) + [more] {
                let glass = NSGlassEffectView()
                glass.cornerRadius = Self.controlHeight / 2
                surfaces[ObjectIdentifier(button)] = glass
                addSubview(glass)
            }
        } else {
            more.contentTintColor = .secondaryLabelColor
        }
        for control in pickers.map(\.button) as [NSView] + [more] + actions { addSubview(control) }
        if let accessory { addSubview(accessory) }
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var isFlipped: Bool { true }

    /// How many pickers the composer carries, for the smoke run's bounds check.
    var pickerCount: Int { pickers.count }

    /// Whether a picker has folded into the More menu for want of room.
    func isFolded(_ button: NSPopUpButton) -> Bool {
        folded.contains { $0 === button }
    }

    /// Opens a picker's menu from the keyboard: its own when it shows, the More menu when folded.
    func showMenu(of button: NSPopUpButton) {
        layoutSubtreeIfNeeded()
        guard !button.isHidden, button.isEnabled else { return }
        (isFolded(button) ? more : button).performClick(nil)
    }

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
        NSSize(width: NSView.noIntrinsicMetric, height: Self.controlHeight)
    }

    override func layout() {
        super.layout()
        let placement = placements(width: bounds.width)
        folded = placement.folded
        for (control, frame) in placement.items { control.frame = frame }
        accessory?.isHidden = !placement.items.contains { $0.0 === accessory }
        more.isHidden = folded.isEmpty
        for slot in pickers {
            // A folded picker keeps its state and its menu, which the More menu copies.
            let isFolded = folded.contains { $0 === slot.button }
            slot.button.alphaValue = isFolded ? 0 : 1
            slot.button.setAccessibilityElement(!isFolded)
            if isFolded { slot.button.frame = NSRect(x: bounds.width, y: 0, width: 0, height: Self.controlHeight) }
        }
        for slot in pickers {
            guard let surface = surfaces[ObjectIdentifier(slot.button)] else { continue }
            surface.isHidden = slot.button.isHidden || isFolded(slot.button)
            surface.frame = NSRect(x: slot.button.frame.minX - Self.surfaceLeading, y: slot.button.frame.minY,
                                   width: slot.button.frame.width + Self.surfaceLeading + Self.surfaceTrailing,
                                   height: slot.button.frame.height)
        }
        if let surface = surfaces[ObjectIdentifier(more)] {
            surface.isHidden = more.isHidden
            surface.frame = more.frame
        }
    }

    /// The capsule is the control as far as anyone clicking it is concerned, padding included.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for button in pickers.map(\.button) + [more] where !button.isHidden && button.isEnabled && !isFolded(button) {
            if surfaces[ObjectIdentifier(button)]?.frame.contains(point) == true {
                button.performClick(nil)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let button = hit as? NSPopUpButton, isFolded(button) { return self }
        return surfaces.values.contains { $0 === hit } ? self : hit
    }

    /// A pop-up's intrinsic width is that of its longest item, which left "Opus 5" adrift in the
    /// space "Claude Sonnet 4.5 (1M context)" would need. It takes the width of what it shows.
    private static func fittedWidth(of button: NSPopUpButton) -> CGFloat {
        let cell = button.cell as? NSPopUpButtonCell
        // A pop-up showing an item of its own, such as a glyph and a longer name, is as wide as that.
        let shown = cell?.usesItemFromMenu == false ? cell?.menuItem : nil
        let title = (shown?.title ?? button.titleOfSelectedItem ?? button.title) as NSString
        let font = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let glyph = shown?.image.map { ceil($0.size.width) + 5 } ?? 0
        // The title, a gap, and either our one chevron or the system's pair of arrows.
        let ownChevron = cell?.arrowPosition == .noArrow
        return ceil(title.size(withAttributes: [.font: font]).width) + glyph + (ownChevron ? 26 : 30)
    }

    private func placements(width: CGFloat) -> (items: [(NSView, NSRect)], folded: [NSPopUpButton]) {
        // Before Auto Layout assigns a width, lay out for a wide row.
        let width = width > 0 ? width : 768
        let padding = surfaces.isEmpty ? 0 : Self.surfaceLeading + Self.surfaceTrailing
        let leading = surfaces.isEmpty ? 0 : Self.surfaceLeading
        let visible = pickers.filter { !$0.button.isHidden }
        func size(_ slot: Slot) -> CGFloat {
            max(slot.minimumWidth, min(slot.maximumWidth, Self.fittedWidth(of: slot.button) + padding))
        }
        let visibleActions = actions.filter { !$0.isHidden }
        let actionWidth = visibleActions.isEmpty ? 0
            : CGFloat(visibleActions.count) * Self.controlHeight + CGFloat(visibleActions.count - 1) * gap
        let room = width - actionWidth - (visibleActions.isEmpty ? 0 : gap * 2)

        // Fold the last pickers until the rest fit beside the More button and the actions.
        var shown = visible
        var folded: [Slot] = []
        func needed(_ slots: [Slot], withMore: Bool) -> CGFloat {
            slots.reduce(0) { $0 + size($1) } + CGFloat(max(0, slots.count - 1)) * gap
                + (withMore ? gap + Self.controlHeight : 0)
        }
        while needed(shown, withMore: !folded.isEmpty) > room,
              let index = shown.lastIndex(where: \.folds) {
            folded.insert(shown.remove(at: index), at: 0)
        }

        var items: [(NSView, NSRect)] = []
        var x: CGFloat = 0
        let overflow = needed(shown, withMore: !folded.isEmpty) - room
        for (index, slot) in shown.enumerated() {
            var slotWidth = size(slot)
            // What still does not fit comes out of the first picker, which truncates its title.
            if index == 0, overflow > 0 { slotWidth = max(min(slotWidth, Self.shortestFirstPicker), slotWidth - overflow) }
            items.append((slot.button, NSRect(x: x + leading, y: 0, width: max(0, slotWidth - padding), height: Self.controlHeight)))
            x += slotWidth + gap
        }
        if !folded.isEmpty {
            items.append((more, NSRect(x: x, y: 0, width: Self.controlHeight, height: Self.controlHeight)))
            x += Self.controlHeight + gap
        }
        var actionX = max(x, width - actionWidth)
        if let accessory, !accessory.stringValue.isEmpty {
            let size = accessory.intrinsicContentSize
            let start = actionX - gap * 2 - ceil(size.width)
            if start >= x {
                items.append((accessory, NSRect(x: start, y: (Self.controlHeight - size.height) / 2,
                                                width: ceil(size.width), height: size.height)))
            }
        }
        for action in visibleActions {
            items.append((action, NSRect(x: actionX, y: 0, width: Self.controlHeight, height: Self.controlHeight)))
            actionX += Self.controlHeight + gap
        }
        return (items, folded.map(\.button))
    }

    // MARK: More menu

    /// Each folded picker as a section: its name, then its choices with the current one checked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === more.menu else { return }
        // A pull-down's first item is its title, never shown in the menu.
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        for button in folded where !button.isHidden {
            if menu.numberOfItems > 1 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: button.accessibilityLabel() ?? ""))
            for (index, source) in (button.menu?.items ?? []).enumerated() {
                let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
                item.subtitle = source.subtitle
                item.indentationLevel = source.indentationLevel
                item.state = source === button.selectedItem ? .on : .off
                if source.representedObject != nil {
                    item.action = #selector(chooseFolded(_:))
                    item.target = self
                    item.representedObject = FoldedChoice(button: button, index: index)
                }
                item.isEnabled = button.isEnabled && source.isEnabled && item.action != nil
                menu.addItem(item)
            }
        }
    }

    @objc private func chooseFolded(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? FoldedChoice, let action = choice.button.action else { return }
        choice.button.selectItem(at: choice.index)
        NSApp.sendAction(action, to: choice.button.target, from: choice.button)
    }

    private final class FoldedChoice {
        let button: NSPopUpButton
        let index: Int
        init(button: NSPopUpButton, index: Int) {
            self.button = button
            self.index = index
        }
    }
}
