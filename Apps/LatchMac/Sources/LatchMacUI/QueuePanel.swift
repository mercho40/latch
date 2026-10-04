import AppKit
import LatchSessionKit

/// Messages written while the agent works, over the composer, in the order they will go: each
/// can go back to the composer to be edited, or be taken out. Hidden while there are none.
@MainActor
final class QueuePanel: NSView {
    private(set) var prompts: [QueuedPrompt] = []
    /// Puts a message back in the composer.
    var onEdit: ((UUID) -> Void)?
    /// Takes a message out without sending it.
    var onRemove: ((UUID) -> Void)?
    private let stack = NSStackView()
    /// Each row's buttons, for tests: Edit, then Remove.
    private(set) var rows: [(id: UUID, label: NSTextField, edit: NSButton, remove: NSButton)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let surface = PlanPanel.surface()
        addSubview(surface)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
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
        ])
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        layer?.shadowRadius = 12
        layer?.shadowOpacity = 0.12
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// One line for a message: its first line, then what goes with it.
    static func line(for prompt: QueuedPrompt) -> String {
        let text = prompt.text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let count = prompt.attachments.count
        let files = count == 0 ? nil : count == 1 ? prompt.attachments[0].name : "\(count) attachments"
        return [text.isEmpty ? nil : text, files.map { text.isEmpty ? $0 : "+ \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    func show(_ prompts: [QueuedPrompt]) {
        guard prompts.map(\.id) != self.prompts.map(\.id) else { return }
        self.prompts = prompts
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        rows = []
        let heading = NSTextField(labelWithString: prompts.count == 1 ? "Sends when the agent finishes" : "\(prompts.count) messages send in turn when the agent finishes")
        heading.font = .systemFont(ofSize: 11)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        for prompt in prompts {
            let symbol = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil) ?? NSImage())
            symbol.contentTintColor = .secondaryLabelColor
            symbol.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            let label = NSTextField(labelWithString: Self.line(for: prompt))
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.toolTip = prompt.text
            let edit = NSButton(title: "Edit", target: self, action: #selector(edited))
            edit.bezelStyle = .accessoryBarAction
            edit.controlSize = .small
            edit.identifier = NSUserInterfaceItemIdentifier(prompt.id.uuidString)
            edit.setAccessibilityLabel("Edit queued message")
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove queued message") ?? NSImage(),
                                  target: self, action: #selector(removed))
            remove.isBordered = false
            remove.contentTintColor = .tertiaryLabelColor
            remove.identifier = edit.identifier
            let row = NSStackView(views: [symbol, label, edit, remove])
            row.orientation = .horizontal
            row.spacing = 6
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            rows.append((prompt.id, label, edit, remove))
        }
    }

    @objc private func edited(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        onEdit?(id)
    }

    @objc private func removed(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        onRemove?(id)
    }
}
