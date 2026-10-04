import LatchACP
import LatchSessionKit
import UIKit

/// The agent asking the user something, such as Claude Code's AskUserQuestion or an MCP
/// server's form: the question as the heading, then each field under its own title and
/// question. A choice is a list with a mark per option, the option's own words and any
/// preview under its title, and, when the agent takes an answer of the user's own, an Other
/// box under the options. What is typed there takes the place of the options, so typing
/// clears the choice and choosing clears the box: what shows chosen is what is sent. Text and
/// numbers are typed, and a switch answers yes or no.
///
/// Submit sends what was given, once every required field has an answer; Skip answers
/// nothing, which Claude Code takes as the user skipping the question; Cancel Request refuses
/// it, which ends the step that asked. As the permission sheet, it cannot be swiped away.
final class QuestionViewController: RequestSheetViewController, UITextFieldDelegate {
    enum Outcome: Equatable {
        case answer([String: QuestionAnswer])
        case skip
        case cancel
    }

    let questionID: UUID
    let form: QuestionForm
    /// What has been given so far, by field, as the model takes it.
    private(set) var answers: [String: QuestionAnswer] = [:]
    private let agentTitle: String
    private let respond: (Outcome) -> Void
    private var responded = false
    /// Each choice's option buttons, by the field's key, in the agent's order.
    private(set) var optionButtons: [String: [UIButton]] = [:]
    /// The text and number fields by their key, and each choice's Other box by its `otherKey`.
    private(set) var textFields: [String: UITextField] = [:]
    private(set) var switches: [String: UISwitch] = [:]
    private(set) var previews: [QuestionPreviewView] = []
    /// The frames around the Other boxes, which look chosen while what is typed is the answer.
    private var otherFrames: [String: UIView] = [:]
    /// Under a number field, while what it holds is not a number.
    private var numberHints: [String: UILabel] = [:]
    private(set) var submitButton = UIButton(type: .system)
    private(set) var skipButton = UIButton(type: .system)
    private(set) var cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    /// Skip and Cancel Request.
    private let secondaryActions = UIStackView()

    convenience init(question: QuestionQueue.Question, agentTitle: String, respond: @escaping (Outcome) -> Void) {
        self.init(id: question.id, form: question.form, agentTitle: agentTitle, respond: respond)
    }

    init(id: UUID, form: QuestionForm, agentTitle: String, respond: @escaping (Outcome) -> Void) {
        questionID = id
        self.form = form
        self.agentTitle = agentTitle
        self.respond = respond
        super.init()
        // A switch always shows an answer, so it always gives the one it shows.
        for field in form.fields where field.kind == .toggle { answers[field.key] = .toggle(false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The list's colour for something waiting on the user, with a question's own mark.
        let heading = headingRow(symbol: "questionmark.circle.fill", tint: SessionStatusView.mark(for: .waiting)?.color ?? .systemOrange,
                                 caption: "\(agentTitle) asks")
        titleLabel.text = form.message
        titleLabel.font = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
            .withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityLabel = "\(agentTitle) asks: \(form.message)"
        let header = UIStackView(arrangedSubviews: [heading, titleLabel])
        header.axis = .vertical
        header.spacing = 10
        content.addArrangedSubview(header)
        content.setCustomSpacing(22, after: header)
        for field in form.fields {
            let section = section(for: field)
            content.addArrangedSubview(section)
            content.setCustomSpacing(28, after: section)
        }
        if let last = content.arrangedSubviews.last { content.setCustomSpacing(18, after: last) }
        content.addArrangedSubview(Self.note(
            "Skip lets \(agentTitle) go on without an answer. Cancel Request refuses the question and ends the step that asked it."))

        var submit = UIButton.Configuration.filled()
        submit.title = "Submit"
        submit.buttonSize = .large
        submit.cornerStyle = .capsule
        submit.titleLineBreakMode = .byWordWrapping
        submitButton = UIButton(configuration: submit, primaryAction: UIAction { [weak self] _ in self?.submit() })
        var skip = UIButton.Configuration.plain()
        skip.title = "Skip"
        skip.baseForegroundColor = LatchPalette.tint
        skip.buttonSize = .large
        skip.titleLineBreakMode = .byWordWrapping
        skipButton = UIButton(configuration: skip, primaryAction: UIAction { [weak self] _ in self?.finish(.skip) })
        var cancel = UIButton.Configuration.plain()
        cancel.title = "Cancel Request"
        cancel.baseForegroundColor = LatchPalette.tint
        cancel.buttonSize = .large
        cancel.titleLineBreakMode = .byWordWrapping
        cancelButton = UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.finish(.cancel) })
        for button in [submitButton, skipButton, cancelButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
            button.isPointerInteractionEnabled = true
        }
        // Skip and Cancel Request side by side under Submit, so the form keeps the room; one
        // above the other at accessibility sizes.
        secondaryActions.addArrangedSubview(skipButton)
        secondaryActions.addArrangedSubview(cancelButton)
        secondaryActions.distribution = .fillEqually
        secondaryActions.spacing = 10
        actions.addArrangedSubview(submitButton)
        actions.addArrangedSubview(secondaryActions)
        arrangeActions()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: QuestionViewController, _) in
            controller.arrangeActions()
        }
        installSheetLayout()
        refreshAnswers()
        // The Other boxes' edges are drawn in a colour resolved for the appearance.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (controller: QuestionViewController, _) in controller.refreshAnswers()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow),
                                               name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    private func arrangeActions() {
        secondaryActions.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
    }

    // MARK: Fields

    /// A field under its title and its question. With a single question the heading is the
    /// question, so a field's that only repeats it is not shown again.
    private func section(for field: QuestionForm.Field) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        let message = form.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = field.prompt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0 == message ? nil : $0 }
        let isChoice = if case .choice = field.kind { true } else { false }
        // A field of a form with nothing else to call it by goes by its key.
        let name = field.title ?? (isChoice || question != nil ? nil : field.key)
        var labels: [UILabel] = []
        if let name, field.kind != .toggle || question != nil {
            let label = UILabel()
            label.text = name
            label.font = ChromeFont.preferred(.footnote, weight: .semibold)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.accessibilityTraits = .header
            labels.append(label)
        }
        if let question, field.kind != .toggle {
            let label = UILabel()
            label.text = question
            label.font = .preferredFont(forTextStyle: .headline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            labels.append(label)
        }
        if case .choice(_, multiple: true) = field.kind {
            let label = Self.note("Choose any that apply.")
            labels.append(label)
        }
        for label in labels { stack.addArrangedSubview(label) }
        for label in labels.dropLast() { stack.setCustomSpacing(4, after: label) }

        switch field.kind {
        case let .choice(options, multiple):
            for option in options { stack.addArrangedSubview(row(for: option, in: field, multiple: multiple)) }
            if let otherKey = field.otherKey { stack.addArrangedSubview(otherBox(for: field, key: otherKey)) }
        case .text:
            stack.addArrangedSubview(textBox(key: field.key, placeholder: "Answer", label: question ?? name ?? field.key, numeric: false))
        case let .number(integer):
            stack.addArrangedSubview(textBox(key: field.key, placeholder: integer ? "Whole number" : "Number",
                                             label: question ?? name ?? field.key, numeric: true))
            let hint = Self.note(integer ? "Enter a whole number." : "Enter a number.")
            hint.textColor = .systemRed
            hint.isHidden = true
            numberHints[field.key] = hint
            stack.addArrangedSubview(hint)
        case .toggle:
            stack.addArrangedSubview(switchRow(key: field.key, text: question ?? name ?? field.key))
        }
        return stack
    }

    /// An option: its title, the agent's words for it under the title, and its mark, a circle
    /// for one of several or a box for any number; then its preview, when it has one.
    private func row(for option: QuestionForm.Option, in field: QuestionForm.Field, multiple: Bool) -> UIView {
        var configuration = UIButton.Configuration.gray()
        configuration.title = option.title
        configuration.subtitle = option.detail
        configuration.titleAlignment = .leading
        configuration.imagePlacement = .leading
        configuration.imagePadding = 12
        configuration.titlePadding = 3
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.subtitleLineBreakMode = .byWordWrapping
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title3)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .body)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .footnote)
            attributes.foregroundColor = UIColor.secondaryLabel
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.choose(option.value, in: field)
        })
        button.contentHorizontalAlignment = .leading
        button.isPointerInteractionEnabled = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        button.accessibilityLabel = option.title
        button.accessibilityValue = option.detail
        button.configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            let chosen = button.isSelected
            configuration.image = UIImage(systemName: multiple ? (chosen ? "checkmark.square.fill" : "square")
                                                               : (chosen ? "checkmark.circle.fill" : "circle"))
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in chosen ? LatchPalette.tint : .tertiaryLabel }
            let look = Self.look(chosen: chosen, pressed: button.isHighlighted)
            configuration.background.backgroundColor = look.fill
            configuration.background.strokeColor = look.edge
            configuration.background.strokeWidth = look.width
            button.configuration = configuration
        }
        optionButtons[field.key, default: []].append(button)
        guard let preview = option.preview, !preview.isEmpty else { return button }
        let previewView = QuestionPreviewView(text: preview, title: option.title)
        previewView.onResize = { [weak self] in
            self?.view.setNeedsLayout()
            self?.sheetPresentationController?.invalidateDetents()
        }
        previews.append(previewView)
        // Set in from the option's edge, so it reads as the option's.
        let indented = UIView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        indented.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: indented.leadingAnchor, constant: 14),
            previewView.trailingAnchor.constraint(equalTo: indented.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: indented.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: indented.bottomAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [button, indented])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    /// A chosen option, or an Other box whose words are the answer, has the tint's tone and edge.
    private static func look(chosen: Bool, pressed: Bool = false) -> (fill: UIColor, edge: UIColor, width: CGFloat) {
        (pressed ? .systemFill : chosen ? LatchPalette.userBubble : .secondarySystemFill,
         chosen ? LatchPalette.tint : .clear, chosen ? 1.5 : 0)
    }

    private func styleFrame(_ frame: UIView, chosen: Bool) {
        let look = Self.look(chosen: chosen)
        frame.backgroundColor = look.fill
        frame.layer.borderWidth = look.width
        frame.layer.borderColor = look.edge.resolvedColor(with: traitCollection).cgColor
    }

    private func otherBox(for field: QuestionForm.Field, key otherKey: String) -> UIView {
        let (frame, textField) = framedField(placeholder: "Other")
        textField.accessibilityLabel = "Other answer"
        textField.accessibilityHint = "Takes the place of the options."
        textField.addAction(UIAction { [weak self, weak textField] _ in
            self?.otherChanged(textField?.text ?? "", for: field, key: otherKey)
        }, for: .editingChanged)
        textFields[otherKey] = textField
        otherFrames[otherKey] = frame
        return frame
    }

    private func textBox(key: String, placeholder: String, label: String, numeric: Bool) -> UIView {
        let (frame, textField) = framedField(placeholder: placeholder)
        textField.accessibilityLabel = label
        if numeric {
            // Signed and decimal numbers need the minus and the point, and Return moves on.
            textField.keyboardType = .numbersAndPunctuation
            textField.autocorrectionType = .no
            textField.spellCheckingType = .no
        }
        textField.addAction(UIAction { [weak self, weak textField] _ in
            self?.textChanged(textField?.text ?? "", key: key)
        }, for: .editingChanged)
        textFields[key] = textField
        return frame
    }

    /// A text field on the same panel as an option, so a typed answer sits among them.
    private func framedField(placeholder: String) -> (UIView, UITextField) {
        let frame = UIView()
        styleFrame(frame, chosen: false)
        frame.layer.cornerRadius = 12
        frame.layer.cornerCurve = .continuous
        let textField = UITextField()
        textField.placeholder = placeholder
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .next
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -10),
            textField.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
            textField.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -8),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        return (frame, textField)
    }

    private func switchRow(key: String, text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        let toggle = UISwitch()
        toggle.accessibilityLabel = text
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            self?.answers[key] = .toggle(toggle?.isOn ?? false)
            self?.refreshAnswers()
        }, for: .valueChanged)
        switches[key] = toggle
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.spacing = 12
        row.alignment = .center
        return row
    }

    // MARK: Answering

    /// One of several takes the place of the last, and tapping it again keeps it unless the
    /// question may go unanswered; any number toggle. Either takes the place of an answer typed
    /// under Other.
    func choose(_ value: String, in field: QuestionForm.Field) {
        guard case let .choice(options, multiple) = field.kind else { return }
        var chosen: [String] = if case let .choices(values)? = answers[field.key] { values } else { [] }
        if multiple {
            if chosen.contains(value) { chosen.removeAll { $0 == value } } else { chosen.append(value) }
            // In the agent's order, whatever the order of the taps.
            let picked = Set(chosen)
            chosen = options.map(\.value).filter { picked.contains($0) }
        } else {
            chosen = chosen == [value] && !field.required ? [] : [value]
        }
        answers[field.key] = chosen.isEmpty ? nil : .choices(chosen)
        if !chosen.isEmpty, let otherKey = field.otherKey, answers[otherKey] != nil {
            answers[otherKey] = nil
            textFields[otherKey]?.text = ""
        }
        refreshAnswers()
    }

    private func otherChanged(_ text: String, for field: QuestionForm.Field, key otherKey: String) {
        let typed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        answers[otherKey] = typed ? .text(text) : nil
        if typed { answers[field.key] = nil }
        refreshAnswers()
    }

    private func textChanged(_ text: String, key: String) {
        answers[key] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
        refreshAnswers()
    }

    /// Number fields holding something that is not a number, which would be sent as nothing.
    private var invalidNumbers: [String] {
        form.fields.compactMap { field in
            guard case let .number(integer) = field.kind, case let .text(text)? = answers[field.key] else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let valid = integer ? Int64(trimmed) != nil : Double(trimmed).map(\.isFinite) == true
            return valid ? nil : field.key
        }
    }

    /// Every required field has an answer, and every number typed is one.
    var canSubmit: Bool { form.isComplete(answers) && invalidNumbers.isEmpty }

    /// The marks, the Other boxes' look, the number hints and Submit follow the answers.
    private func refreshAnswers() {
        for field in form.fields {
            guard case let .choice(options, _) = field.kind else { continue }
            let chosen: [String] = if case let .choices(values)? = answers[field.key] { values } else { [] }
            for (option, button) in zip(options, optionButtons[field.key] ?? []) {
                button.isSelected = chosen.contains(option.value)
                button.accessibilityTraits = button.isSelected ? [.button, .selected] : .button
            }
            if let otherKey = field.otherKey, let frame = otherFrames[otherKey] { styleFrame(frame, chosen: answers[otherKey] != nil) }
        }
        let invalid = Set(invalidNumbers)
        var resized = false
        for (key, hint) in numberHints where hint.isHidden == invalid.contains(key) {
            hint.isHidden = !invalid.contains(key)
            resized = true
        }
        if resized { sheetPresentationController?.invalidateDetents() }
        submitButton.isEnabled = canSubmit
        submitButton.accessibilityHint = canSubmit ? nil
            : form.fields.count == 1 ? "Answer the question first." : "Answer the required questions first."
    }

    func submit() {
        guard canSubmit else { return }
        finish(.answer(answers))
    }

    override func cancelRequest() { finish(.cancel) }

    /// The answer, once. Dismissal follows from the queue moving on.
    private func finish(_ outcome: Outcome) {
        guard !responded else { return }
        responded = true
        view.endEditing(true)
        respond(outcome)
    }

    override var firstFocus: Any? { titleLabel }

    /// ⌘Return submits, as it sends from the composer; Escape cancels.
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [UIKeyCommand(title: "Submit", action: #selector(submitFromKeyboard), input: "\r", modifierFlags: .command)]
    }

    @objc private func submitFromKeyboard() { submit() }

    // MARK: Keyboard

    /// Typing wants the whole height: the keyboard takes the lower half of the sheet.
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let sheet = sheetPresentationController, sheet.selectedDetentIdentifier != .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        reveal(textField)
    }

    /// Return moves to the next field, and from the last puts the keyboard away.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = form.fields.flatMap { [$0.key] + ($0.otherKey.map { [$0] } ?? []) }.compactMap { textFields[$0] }
        if let index = order.firstIndex(of: textField), index + 1 < order.count {
            order[index + 1].becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    @objc private func keyboardDidShow() {
        guard let field = textFields.values.first(where: \.isFirstResponder) else { return }
        reveal(field)
    }

    /// Scrolls the field's panel into the part of the sheet the keyboard leaves.
    private func reveal(_ textField: UITextField) {
        guard let frame = textField.superview else { return }
        view.layoutIfNeeded()
        scrollView.scrollRectToVisible(frame.convert(frame.bounds, to: scrollView).insetBy(dx: 0, dy: -12), animated: true)
    }
}

/// An option's preview, such as a mockup or a snippet: monospaced and never wrapped, as the
/// agent drew it, panning sideways when a line is long. A long one shows its first lines,
/// and Show All the rest. VoiceOver reads it whole.
final class QuestionPreviewView: UIView {
    let text: String
    private let lines: [Substring]
    private let label = UILabel()
    private let scrollView = FadingScrollView()
    private lazy var labelWidth = label.widthAnchor.constraint(equalToConstant: 0)
    private lazy var labelHeight = label.heightAnchor.constraint(equalToConstant: 0)
    let toggle = UIButton(type: .system)
    private(set) var isExpanded = false
    /// The preview changed height, as Show All does.
    var onResize: (() -> Void)?
    static let collapsedLines = 6
    private static let padding: CGFloat = 12

    init(text: String, title: String) {
        self.text = text
        lines = CodeBlockView.cutting(text, toLinesOf: 400).split(separator: "\n", omittingEmptySubsequences: false)
        super.init(frame: .zero)
        backgroundColor = LatchPalette.codeBackground
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        label.numberOfLines = 0
        label.isAccessibilityElement = true
        label.accessibilityLabel = "Preview of \(title)"
        label.accessibilityValue = text
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInset = .init(top: 0, left: Self.padding, bottom: 0, right: Self.padding)
        label.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(label)

        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = LatchPalette.tint
        configuration.buttonSize = .small
        configuration.contentInsets = .init(top: 8, leading: Self.padding, bottom: 8, trailing: Self.padding)
        toggle.configuration = configuration
        toggle.contentHorizontalAlignment = .leading
        toggle.addAction(UIAction { [weak self] _ in self?.toggleExpanded() }, for: .primaryActionTriggered)
        // VoiceOver reads the whole preview, so it has no use for the button.
        toggle.accessibilityElementsHidden = true
        toggle.isHidden = lines.count <= Self.collapsedLines + 1

        let stack = UIStackView(arrangedSubviews: [scrollView, toggle])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: toggle.isHidden ? -10 : 0),
            label.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: label.heightAnchor),
            labelWidth, labelHeight,
        ])
        show()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (view: QuestionPreviewView, _) in
            view.show()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The lines on show, measured unwrapped: a line is as long as it is.
    private func show() {
        let shown = isExpanded || toggle.isHidden ? lines : Array(lines.prefix(Self.collapsedLines))
        let size = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: size, weight: UIFont.Weight.regular.adjusted(for: traitCollection)), compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 2
        let text = NSAttributedString(string: shown.joined(separator: "\n"), attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ])
        label.attributedText = text
        let measured = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        labelWidth.constant = ceil(max(measured.width, 1)) + 2
        labelHeight.constant = ceil(max(measured.height, font.lineHeight))
        var configuration = toggle.configuration
        configuration?.title = isExpanded ? "Show Less" : "Show All \(lines.count) Lines"
        toggle.configuration = configuration
    }

    private func toggleExpanded() {
        isExpanded.toggle()
        show()
        onResize?()
    }
}
