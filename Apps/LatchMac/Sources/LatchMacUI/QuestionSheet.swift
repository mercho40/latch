import AppKit
import LatchSessionKit

/// The agent's question as a sheet, such as Claude Code's AskUserQuestion: its message, then
/// each field, then Cancel Request, Skip and Submit. Submit sends what was given, Skip tells
/// the agent the question went unanswered, and Cancel Request refuses it, which ends the call
/// that asked. Return submits once every required field has an answer; Escape cancels.
@MainActor
final class QuestionSheet: NSObject, NSTextFieldDelegate {
    enum Outcome: Equatable {
        case answer([String: QuestionAnswer])
        case skip
        case cancel
    }

    static let width: CGFloat = 520
    static let maximumContentHeight: CGFloat = 460

    let question: QuestionQueue.Question
    let panel: NSPanel
    private(set) var answers: [String: QuestionAnswer] = [:]
    var onFinish: ((Outcome) -> Void)?
    let submit = NSButton(title: "Submit", target: nil, action: nil)
    /// Each choice's buttons, by field, with the option's value.
    private(set) var choices: [String: [(value: String, button: NSButton)]] = [:]
    /// The fields that take typing, by key: an "Other" answer, text or a number.
    private(set) var textFields: [String: NSTextField] = [:]

    init(question: QuestionQueue.Question) {
        self.question = question
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.titled, .docModalWindow],
                        backing: .buffered, defer: true)
        super.init()
        build()
    }

    /// Picks options, as a click would: the option values for a choice.
    func choose(_ values: [String], for key: String) {
        for (value, button) in choices[key] ?? [] { button.state = values.contains(value) ? .on : .off }
        if let button = choices[key]?.first?.button { choiceChanged(button) }
    }

    /// Types into a field, as the user would.
    func type(_ text: String, into key: String) {
        guard let field = textFields[key] else { return }
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func build() {
        let form = question.form
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = Self.label(form.message, font: .systemFont(ofSize: 13, weight: .semibold))
        heading.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(heading)
        for field in form.fields {
            let group = fieldView(field)
            stack.addArrangedSubview(group)
            stack.setCustomSpacing(16, after: group)
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel Request", target: self, action: #selector(cancelled))
        cancel.keyEquivalent = "\u{1b}"
        let skip = NSButton(title: "Skip", target: self, action: #selector(skipped))
        submit.target = self
        submit.action = #selector(submitted)
        submit.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, NSView(), skip, submit])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        panel.contentView = content
        for text in stack.arrangedSubviews.flatMap(Self.wrappingLabels) {
            text.preferredMaxLayoutWidth = Self.width - 40 - 24
        }
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        // As tall as the questions, up to a height that leaves the window to be seen around it.
        content.layoutSubtreeIfNeeded()
        let height = min(stack.fittingSize.height, Self.maximumContentHeight)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        panel.setContentSize(NSSize(width: Self.width, height: height + buttons.fittingSize.height))
        refreshSubmit()
    }

    private func fieldView(_ field: QuestionForm.Field) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        if let title = field.title {
            group.addArrangedSubview(Self.label(title, font: .systemFont(ofSize: 12, weight: .semibold)))
        }
        if let prompt = field.prompt {
            group.addArrangedSubview(Self.label(prompt, font: .systemFont(ofSize: 12)))
        }
        switch field.kind {
        case let .choice(options, multiple):
            var buttons: [(String, NSButton)] = []
            for option in options {
                let button = multiple ? NSButton(checkboxWithTitle: option.title, target: self, action: #selector(choiceChanged))
                    : NSButton(radioButtonWithTitle: option.title, target: self, action: #selector(choiceChanged))
                button.identifier = NSUserInterfaceItemIdentifier(field.key)
                buttons.append((option.value, button))
                let row = NSStackView()
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 2
                row.addArrangedSubview(button)
                // Under the option, in from its button: what it means, and what it would look like.
                if let detail = option.detail {
                    let label = Self.label(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                    row.addArrangedSubview(Self.indented(label))
                }
                if let preview = option.preview {
                    let label = Self.label(preview, font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: .secondaryLabelColor)
                    label.maximumNumberOfLines = 8
                    label.lineBreakMode = .byTruncatingTail
                    row.addArrangedSubview(Self.indented(label))
                }
                group.addArrangedSubview(row)
            }
            choices[field.key] = buttons.map { (value: $0.0, button: $0.1) }
            if let other = field.otherKey {
                let input = textField(key: other, placeholder: "Other: write your own answer")
                group.addArrangedSubview(input)
            }
        case .text:
            group.addArrangedSubview(textField(key: field.key, placeholder: field.required ? "Required" : "Optional"))
        case let .number(integer):
            group.addArrangedSubview(textField(key: field.key, placeholder: integer ? "A whole number" : "A number"))
        case .toggle:
            let box = NSButton(checkboxWithTitle: field.title ?? "Yes", target: self, action: #selector(toggled))
            box.identifier = NSUserInterfaceItemIdentifier(field.key)
            answers[field.key] = .toggle(false)
            group.addArrangedSubview(box)
        }
        return group
    }

    private func textField(key: String, placeholder: String) -> NSTextField {
        let input = NSTextField()
        input.placeholderString = placeholder
        input.delegate = self
        input.identifier = NSUserInterfaceItemIdentifier(key)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.widthAnchor.constraint(equalToConstant: Self.width - 40).isActive = true
        textFields[key] = input
        return input
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let buttons = choices[key],
              let field = question.form.fields.first(where: { $0.key == key }) else { return }
        // Radio buttons in different rows do not exclude each other by themselves.
        if case .choice(_, false) = field.kind, sender.state == .on {
            for (_, button) in buttons where button !== sender { button.state = .off }
        }
        let chosen = buttons.filter { $0.button.state == .on }.map(\.value)
        answers[key] = chosen.isEmpty ? nil : .choices(chosen)
        // Choosing an option takes the place of an answer of the user's own.
        if !chosen.isEmpty, let other = field.otherKey, let input = textFields[other], !input.stringValue.isEmpty {
            input.stringValue = ""
            answers[other] = nil
        }
        refreshSubmit()
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        answers[key] = .toggle(sender.state == .on)
        refreshSubmit()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let input = notification.object as? NSTextField, let key = input.identifier?.rawValue else { return }
        let text = input.stringValue
        answers[key] = text.isEmpty ? nil : .text(text)
        // An answer of the user's own takes the place of the options above it.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let field = question.form.fields.first(where: { $0.otherKey == key }) {
            for (_, button) in choices[field.key] ?? [] { button.state = .off }
            answers[field.key] = nil
        }
        refreshSubmit()
    }

    private func refreshSubmit() {
        submit.isEnabled = question.form.isComplete(answers)
    }

    @objc private func submitted() {
        guard submit.isEnabled else { return }
        onFinish?(.answer(answers))
    }

    @objc private func skipped() { onFinish?(.skip) }
    @objc private func cancelled() { onFinish?(.cancel) }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        return label
    }

    private static func indented(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return wrapper
    }

    private static func wrappingLabels(in view: NSView) -> [NSTextField] {
        if let label = view as? NSTextField, label.cell?.wraps == true, !label.isEditable { return [label] }
        return view.subviews.flatMap(wrappingLabels)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
