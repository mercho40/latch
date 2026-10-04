import LatchACP
import LatchSessionKit
import UIKit

/// An agent asking before it acts: what it wants to do, in its own heading when it gives one,
/// such as Claude Code's "Ready to code?", and why; the tool call's details as the agent sent
/// them, or the plan it asks to go ahead with, as Markdown; one button per option it offers in
/// its order, and Cancel Request. Every button says Latch's own label; the agent's words for an
/// option, such as "Yes, and don't ask again for git commands", go under the label, never in
/// its place, so no option can pass itself off as another. No option is the default, by look
/// or by key.
final class PermissionRequestViewController: RequestSheetViewController {
    let promptID: UUID
    let options: [ACPPermissionOption]
    /// The agent's heading for the request, or the tool call's title.
    let requestTitle: String
    /// Why, when the agent says.
    let reason: String?
    /// The plan the agent asks to go ahead with, shown in place of the details.
    let plan: String?
    /// The agent's own words for each option that has some, by option ID.
    let optionDetails: [String: String]
    let details: String
    /// The request is a shell command, set in monospace as the transcript sets it.
    let isCommand: Bool
    /// The details would only repeat the command in the title, so they are not shown.
    let detailsRepeatTitle: Bool
    private let agentTitle: String
    private let decide: (String?) -> Void
    private var decided = false
    private(set) var optionButtons: [UIButton] = []
    private(set) var cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    /// The plan, rendered, when there is one.
    private(set) var planView: MarkdownContentView?
    private static let planPadding: CGFloat = 14

    init(prompt: PermissionQueue.Prompt, agentTitle: String, decide: @escaping (String?) -> Void) {
        promptID = prompt.id
        options = prompt.options
        self.agentTitle = agentTitle
        self.decide = decide
        let described = Self.describe(prompt.request)
        details = described.details
        requestTitle = prompt.heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? described.title
        reason = prompt.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        plan = prompt.plan
        optionDetails = Dictionary(prompt.options.compactMap { option in prompt.detail(for: option).map { (option.optionId, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        // Only the tool call's own title can be a command: a heading the agent wrote is prose.
        let titled = requestTitle == described.title
        let command = Self.command(of: prompt.request)
        let bare = ToolCallPresentation(text: requestTitle)
        isCommand = titled && (bare.isCommand || command != nil || Self.kind(of: prompt.request) == "execute")
        // Only when the input is the command alone, and the details say nothing else.
        detailsRepeatTitle = titled && command.map { $0 == bare.displayTitle } == true
            && details.components(separatedBy: "\n\n").allSatisfy { $0.hasPrefix("rawInput (") }
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The tool call's title, and its details the way the transcript shows a tool call's.
    /// Anything the details cannot describe is shown as the JSON the agent sent.
    static func describe(_ request: ACPPermissionRequest) -> (title: String, details: String) {
        var title = ""
        var details = ""
        if case var .object(call) = request.toolCall {
            if case let .string(value)? = call["title"] { title = value }
            call["sessionUpdate"] = .string("tool_call")
            if call["toolCallId"] == nil { call["toolCallId"] = .string("permission") }
            let notification = ACPSessionNotification(sessionId: request.sessionId, update: .object(call))
            if case let .toolCall(event, _) = notification.event {
                var summary = ToolCallDetails()
                summary.apply(event)
                details = summary.text
            }
        }
        if details.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            details = (try? encoder.encode(request.toolCall)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return (title.trimmingCharacters(in: .whitespacesAndNewlines), details)
    }

    /// The command, when the agent's input is exactly `{"command": …}`.
    static func command(of request: ACPPermissionRequest) -> String? {
        guard case let .object(call) = request.toolCall, case let .object(input)? = call["rawInput"],
              input.count == 1, case let .string(command)? = input["command"] else { return nil }
        return command
    }

    private static func kind(of request: ACPPermissionRequest) -> String? {
        guard case let .object(call) = request.toolCall, case let .string(kind)? = call["kind"] else { return nil }
        return kind
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The list's "Needs approval" mark, so a decision looks the same wherever it waits.
        let mark = SessionStatusView.mark(for: .waiting)
        let heading = headingRow(symbol: mark?.symbol ?? "exclamationmark.circle.fill", tint: mark?.color ?? .systemOrange,
                                 caption: "\(agentTitle) requests permission")

        let shownTitle = requestTitle.isEmpty ? "Permission Request" : ToolCallPresentation(text: requestTitle).displayTitle
        titleLabel.text = shownTitle
        titleLabel.font = isCommand
            ? UIFontMetrics(forTextStyle: .title3).scaledFont(for: .monospacedSystemFont(ofSize: 18, weight: .semibold))
            : UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title3)
                .withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        // The command is read symbol by symbol: `rm -rf .build` and `rm -rf ~/` differ by little.
        let spoken = NSMutableAttributedString(string: "\(agentTitle) requests permission: ")
        spoken.append(NSAttributedString(string: shownTitle, attributes: isCommand ? [.accessibilitySpeechPunctuation: true] : [:]))
        titleLabel.accessibilityAttributedLabel = spoken

        let header = UIStackView(arrangedSubviews: [heading, titleLabel])
        header.axis = .vertical
        header.spacing = 10
        if let reason, !reason.isEmpty {
            let label = UILabel()
            label.text = reason
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            header.addArrangedSubview(label)
            header.setCustomSpacing(6, after: titleLabel)
        }
        content.addArrangedSubview(header)

        if let plan {
            content.addArrangedSubview(makePlanBox(plan))
        } else if !detailsRepeatTitle, !details.isEmpty {
            content.addArrangedSubview(makeDetailsBox())
        }
        // After what is asked, so it is the first thing read.
        let explanation = Self.note(
            "“Always” is remembered by \(agentTitle), not by Latch. Cancel Request declines only this request; it doesn’t restrict the agent.")
        content.addArrangedSubview(explanation)
        if let box = content.arrangedSubviews.dropLast().last, box !== header { content.setCustomSpacing(10, after: box) }

        // With the agent's words under some labels, every button is a rounded rectangle, so
        // they all keep one look.
        let worded = !optionDetails.isEmpty
        for option in options {
            var configuration = UIButton.Configuration.gray()
            configuration.title = option.permissionLabel
            configuration.subtitle = optionDetails[option.optionId]
            configuration.buttonSize = .large
            configuration.cornerStyle = worded ? .large : .capsule
            configuration.titleLineBreakMode = .byWordWrapping
            configuration.subtitleLineBreakMode = .byWordWrapping
            configuration.titlePadding = 3
            configuration.titleAlignment = .center
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.preferredFont(forTextStyle: .footnote)
                attributes.foregroundColor = UIColor.secondaryLabel
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.finish(option.optionId)
            })
            // Latch's label is the button's name; the agent's words are only its value.
            button.accessibilityLabel = option.permissionLabel
            button.accessibilityValue = optionDetails[option.optionId]
            button.isPointerInteractionEnabled = true
            actions.addArrangedSubview(button)
            optionButtons.append(button)
        }
        var cancel = UIButton.Configuration.plain()
        cancel.title = "Cancel Request"
        cancel.baseForegroundColor = LatchPalette.tint
        cancel.buttonSize = .large
        cancel.titleLineBreakMode = .byWordWrapping
        cancelButton = UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.finish(nil) })
        cancelButton.isPointerInteractionEnabled = true
        for button in optionButtons + [cancelButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        }
        actions.addArrangedSubview(cancelButton)
        installSheetLayout()
    }

    private func makeDetailsBox() -> UIView {
        let detailsBox = UIView()
        detailsBox.backgroundColor = LatchPalette.codeBackground
        detailsBox.layer.cornerRadius = 12
        detailsBox.layer.cornerCurve = .continuous
        let detailsView = UITextView()
        detailsView.isEditable = false
        detailsView.isSelectable = true
        detailsView.isScrollEnabled = false
        detailsView.dataDetectorTypes = []
        detailsView.backgroundColor = .clear
        detailsView.textContainerInset = .zero
        detailsView.textContainer.lineFragmentPadding = 0
        detailsView.adjustsFontForContentSizeCategory = true
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12.5, weight: .regular))
        let bold = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 12.5, weight: .semibold))
        let styled = NSMutableAttributedString(attributedString: ToolCallPresentation.styledDetails(details, font: font, boldFont: bold))
        styled.addAttribute(.accessibilitySpeechPunctuation, value: true, range: NSRange(location: 0, length: styled.length))
        detailsView.attributedText = styled
        detailsView.accessibilityLabel = "Tool details"
        detailsView.translatesAutoresizingMaskIntoConstraints = false
        detailsBox.addSubview(detailsView)
        NSLayoutConstraint.activate([
            detailsView.leadingAnchor.constraint(equalTo: detailsBox.leadingAnchor, constant: 12),
            detailsView.trailingAnchor.constraint(equalTo: detailsBox.trailingAnchor, constant: -12),
            detailsView.topAnchor.constraint(equalTo: detailsBox.topAnchor, constant: 10),
            detailsView.bottomAnchor.constraint(equalTo: detailsBox.bottomAnchor, constant: -10),
        ])
        return detailsBox
    }

    /// The plan as a reply would show it, in a frame, as Claude Code frames it.
    private func makePlanBox(_ plan: String) -> UIView {
        let box = UIView()
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        let markdown = MarkdownContentView()
        markdown.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(markdown)
        let padding = Self.planPadding
        NSLayoutConstraint.activate([
            markdown.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            markdown.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            markdown.topAnchor.constraint(equalTo: box.topAnchor, constant: padding),
            markdown.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding),
        ])
        planView = markdown
        // VoiceOver says "Plan" on the way in, then reads it block by block.
        box.accessibilityLabel = "Plan"
        box.accessibilityContainerType = .semanticGroup
        renderPlan()
        Self.styleFrame(box)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            (controller: PermissionRequestViewController, _) in controller.renderPlan()
        }
        box.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (box: UIView, _) in
            Self.styleFrame(box)
        }
        return box
    }

    private static func styleFrame(_ box: UIView) {
        let high = box.traitCollection.accessibilityContrast == .high
        box.layer.borderWidth = high ? 1.5 : 1
        box.layer.borderColor = (high ? UIColor.label : .separator).resolvedColor(with: box.traitCollection).cgColor
    }

    private func renderPlan() {
        guard let plan, let planView else { return }
        let renderer = MarkdownRenderer(traits: traitCollection)
        planView.show(renderer.render(plan), renderer: renderer)
        sheetPresentationController?.invalidateDetents()
    }

    override func prepare(width: CGFloat) {
        planView?.prepare(width: width - Self.planPadding * 2)
    }

    override var firstFocus: Any? { titleLabel }

    override func cancelRequest() { finish(nil) }

    /// The decision, once. Dismissal follows from the queue moving on.
    func finish(_ optionID: String?) {
        guard !decided else { return }
        decided = true
        decide(optionID)
    }
}
