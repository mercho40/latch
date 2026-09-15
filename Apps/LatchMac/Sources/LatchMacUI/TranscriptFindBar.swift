import AppKit

/// The find bar above a transcript: ⌘F opens it, Return and ⌘G step forward, ⇧⌘G steps
/// back, Escape closes it. Matching is case- and diacritic-insensitive.
@MainActor
final class TranscriptFindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 36

    let field = NSSearchField()
    var onSearch: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let count = NSTextField(labelWithString: "")
    private let steppers = NSSegmentedControl(
        images: [NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
                 NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!],
        trackingMode: .momentary, target: nil, action: nil
    )
    private let done = NSButton(title: "Done", target: nil, action: nil)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        field.placeholderString = "Find in conversation"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(search)
        field.setAccessibilityLabel("Find in conversation")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setAccessibilityLabel("Match count")
        steppers.target = self
        steppers.action = #selector(step)
        steppers.setAccessibilityLabel("Step through matches")
        done.bezelStyle = .rounded
        done.target = self
        done.action = #selector(close)
        for view in [field, count, steppers, done] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let y = (bounds.height - 24) / 2
        done.sizeToFit()
        let doneWidth = max(60, done.frame.width)
        let stepperWidth: CGFloat = 60
        let countWidth: CGFloat = 90
        let fieldWidth = max(80, bounds.width - inset * 2 - doneWidth - stepperWidth - countWidth - 24)
        field.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 24)
        count.frame = NSRect(x: field.frame.maxX + 8, y: y + 4, width: countWidth, height: 16)
        steppers.frame = NSRect(x: count.frame.maxX + 8, y: y, width: stepperWidth, height: 24)
        done.frame = NSRect(x: bounds.width - inset - doneWidth, y: y, width: doneWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setStatus(index: Int, total: Int) {
        if total == 0 {
            count.stringValue = field.stringValue.isEmpty ? "" : "No matches"
        } else {
            count.stringValue = "\(index) of \(total)"
        }
    }

    @objc private func search() { onSearch?(field.stringValue) }

    @objc private func step() {
        steppers.selectedSegment == 0 ? onPrevious?() : onNext?()
    }

    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onNext?()
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            onPrevious?()
            return true
        default:
            return false
        }
    }
}
