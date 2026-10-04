import AppKit
import LatchACP

/// The agent's plan for the work in hand, over the composer: one line saying how far it has got
/// and what it is doing now, which opens into the whole list. Hidden while the agent has none.
@MainActor
final class PlanPanel: NSView {
    static let cornerRadius: CGFloat = 14
    /// More steps than this are summed up in a last line rather than listed.
    static let maximumListedSteps = 12

    private(set) var entries: [ACPPlanEntry] = []
    private(set) var expanded = false
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let list = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            surface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .menu
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Self.cornerRadius
            material.layer?.masksToBounds = true
            surface = material
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        toggle.isBordered = false
        toggle.imagePosition = .imageLeading
        toggle.alignment = .left
        toggle.target = self
        toggle.action = #selector(toggled)
        (toggle.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        toggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        list.isSelectable = true
        list.isHidden = true
        list.setAccessibilityLabel("Plan steps")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(list)
        addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toggle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        layer?.shadowRadius = 12
        layer?.shadowOpacity = 0.12
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// The steps done and in all, and the one in hand: the one in progress, else the next pending.
    static func summary(of entries: [ACPPlanEntry]) -> (done: Int, total: Int, current: String?) {
        let current = entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending }
        return (entries.filter { $0.status == .completed }.count, entries.count, current?.content)
    }

    func show(_ entries: [ACPPlanEntry]) {
        guard entries != self.entries else { return }
        self.entries = entries
        refresh()
    }

    @objc private func toggled() {
        expanded.toggle()
        refresh()
    }

    private func refresh() {
        let (done, total, current) = Self.summary(of: entries)
        let font = NSFont.systemFont(ofSize: 12)
        let title = NSMutableAttributedString(string: "Plan · \(done) of \(total)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        if let current, !expanded {
            title.append(NSAttributedString(string: "   " + current, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        toggle.attributedTitle = title
        let chevron = expanded ? "chevron.down" : "chevron.right"
        toggle.image = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        toggle.contentTintColor = .secondaryLabelColor
        // A step in progress is being done now; the first pending one is only next.
        let started = entries.contains { $0.status == .inProgress }
        toggle.setAccessibilityLabel("Plan, \(done) of \(total) done" + (current.map { ", \(started ? "now" : "next"): \($0)" } ?? ""))
        toggle.setAccessibilityValue(expanded ? "expanded" : "collapsed")
        list.attributedStringValue = expanded ? Self.checklist(entries, font: font) : NSAttributedString()
        list.isHidden = !expanded
    }

    /// One line per step: an open circle, a filled one for the step in hand, a tick for one
    /// done, which is also struck through, so the state never rests on colour alone.
    static func checklist(_ entries: [ACPPlanEntry], font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.headIndent = font.pointSize + 6
        let result = NSMutableAttributedString()
        for (index, entry) in entries.prefix(maximumListedSteps).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let (symbol, tint): (String, NSColor) = switch entry.status {
            case .pending: ("circle", .tertiaryLabelColor)
            case .inProgress: ("circle.inset.filled", .controlAccentColor)
            case .completed: ("checkmark.circle.fill", .secondaryLabelColor)
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(.init(paletteColors: [tint]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let glyph = NSTextAttachment()
                glyph.image = image
                glyph.bounds = NSRect(x: 0, y: font.descender / 2, width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: glyph))
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph,
                                                             .foregroundColor: entry.status == .completed ? NSColor.secondaryLabelColor : NSColor.labelColor]
            if entry.status == .completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if entry.status == .inProgress { attributes[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .medium) }
            result.append(NSAttributedString(string: " " + entry.content, attributes: attributes))
        }
        if entries.count > maximumListedSteps {
            result.append(NSAttributedString(string: "\nand \(entries.count - maximumListedSteps) more", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }
        return result
    }
}
