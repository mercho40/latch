import LatchACP
import LatchSessionKit
import UIKit

/// An agent asking before it acts: what it wants to do, the tool call's details as the agent
/// sent them, one button per option it offers in its order, and Cancel Request. No option is
/// the default, by look or by key, and the sheet cannot be swiped away: it closes with a
/// decision, or on its own when the request does.
///
/// The request always comes first. The options and Cancel Request stay pinned below it only
/// while they leave most of the sheet to the request; when they would not, as at accessibility
/// text sizes, all of them follow the details in the scrolling area, together, so nobody
/// decides without having scrolled past what is asked, and Cancel is never the only choice
/// in sight.
final class PermissionRequestViewController: UIViewController {
    let promptID: UUID
    let options: [ACPPermissionOption]
    let requestTitle: String
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
    private let heading = UIStackView()
    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let optionStack = UIStackView()
    private let pinned = UIStackView()
    /// The scrolling area ends above the pinned options, or with them inside it, at the sheet's edge.
    private var scrollAbovePinned: NSLayoutConstraint?
    private var scrollToEdge: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?
    /// Whether the options are pinned below the scrolling request, or follow it inside.
    private(set) var optionsArePinned = true
    /// Called when the sheet goes without a decision or a closed request taking it down.
    var onDismissedElsewhere: (() -> Void)?

    static let fitDetent = UISheetPresentationController.Detent.Identifier("fit")

    init(prompt: PermissionQueue.Prompt, agentTitle: String, decide: @escaping (String?) -> Void) {
        promptID = prompt.id
        options = prompt.options
        self.agentTitle = agentTitle
        self.decide = decide
        (requestTitle, details) = Self.describe(prompt.request)
        let command = Self.command(of: prompt.request)
        let bare = ToolCallPresentation(text: requestTitle)
        isCommand = bare.isCommand || command != nil || Self.kind(of: prompt.request) == "execute"
        // Only when the input is the command alone, and the details say nothing else.
        detailsRepeatTitle = command.map { $0 == bare.displayTitle } == true
            && details.components(separatedBy: "\n\n").allSatisfy { $0.hasPrefix("rawInput (") }
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
        // A centred form on an iPad; a sheet from the bottom on an iPhone.
        modalPresentationStyle = .formSheet
        if let sheet = sheetPresentationController {
            // As tall as the request needs, or the whole height.
            sheet.detents = [.custom(identifier: Self.fitDetent) { [weak self] context in
                self.map { min($0.fittingHeight, context.maximumDetentValue) }
            }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
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
        view.backgroundColor = .systemBackground

        // The list's "Needs approval" mark, so a decision looks the same wherever it waits.
        let mark = SessionStatusView.mark(for: .waiting)
        let icon = UIImageView(image: UIImage(systemName: mark?.symbol ?? "exclamationmark.circle.fill"))
        icon.tintColor = mark?.color ?? .systemOrange
        icon.preferredSymbolConfiguration = .init(textStyle: .title2)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        // At accessibility sizes the heading grows less than the request, so the options come
        // into view sooner.
        icon.maximumContentSizeCategory = .accessibilityMedium

        let caption = UILabel()
        caption.text = "\(agentTitle) requests permission"
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.maximumContentSizeCategory = .accessibilityMedium
        // The title says it for VoiceOver, where focus lands.
        caption.isAccessibilityElement = false

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

        // After the details, so the command is the first thing read.
        let explanation = UILabel()
        explanation.text = "“Always” is remembered by \(agentTitle), not by Latch. Cancel Request declines only this request; it doesn’t restrict the agent."
        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0

        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(caption)
        heading.spacing = 8
        let header = UIStackView(arrangedSubviews: [heading, titleLabel])
        header.axis = .vertical
        header.spacing = 10

        optionStack.axis = .vertical
        optionStack.spacing = 10
        for option in options {
            var configuration = UIButton.Configuration.gray()
            configuration.title = option.permissionLabel
            configuration.buttonSize = .large
            configuration.cornerStyle = .capsule
            configuration.titleLineBreakMode = .byWordWrapping
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.finish(option.optionId)
            })
            button.isPointerInteractionEnabled = true
            optionStack.addArrangedSubview(button)
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

        content.addArrangedSubview(header)
        content.addArrangedSubview(detailsBox)
        content.addArrangedSubview(explanation)
        content.axis = .vertical
        content.spacing = 16
        content.setCustomSpacing(10, after: detailsBox)
        detailsBox.isHidden = detailsRepeatTitle || details.isEmpty
        pinned.axis = .vertical
        pinned.spacing = 10
        pinned.addArrangedSubview(optionStack)
        pinned.addArrangedSubview(cancelButton)

        scrollView.alwaysBounceVertical = false
        for view in [content, pinned, scrollView] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        scrollView.addSubview(content)
        view.addSubview(scrollView)
        view.addSubview(pinned)
        let guide = view.readableContentGuide
        let abovePinned = scrollView.bottomAnchor.constraint(equalTo: pinned.topAnchor, constant: -12)
        let bottom = content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4)
        scrollAbovePinned = abovePinned
        scrollToEdge = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        contentBottom = bottom
        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            abovePinned,
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Self.topInset),
            bottom,
            pinned.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ]
        // The readable width, and never closer than 20 points to the sheet's edge.
        for column in [content, pinned] as [UIView] {
            let leading = column.leadingAnchor.constraint(equalTo: guide.leadingAnchor)
            let trailing = column.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
            leading.priority = .defaultHigh
            trailing.priority = .defaultHigh
            constraints += [
                leading, trailing,
                column.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
                column.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
                column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        pinned.setContentCompressionResistancePriority(.required, for: .vertical)
        // What scrolls under the pinned options fades into them rather than stopping at a hard line.
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = scrollView
            edge.edge = .bottom
            pinned.addInteraction(edge)
            scrollView.bottomEdgeEffect.style = .soft
        }
        arrangeHeading()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: PermissionRequestViewController, _) in
            controller.arrangeHeading()
            controller.sheetPresentationController?.invalidateDetents()
        }
    }

    private static let topInset: CGFloat = 28

    /// At accessibility sizes the hand goes above the caption, so the caption keeps its width.
    private func arrangeHeading() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        heading.axis = large ? .vertical : .horizontal
        heading.alignment = large ? .leading : .center
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Pinned only while the options leave the request most of the sheet at its tallest.
        // Measured against the window, not this sheet, whose height follows the choice.
        // Measured, not read from frames, which this pass has not yet set below the top level.
        guard view.bounds.height > 0 else { return }
        let options = height(of: optionStack) + height(of: cancelButton)
        let pin = options <= (view.window?.bounds.height ?? view.bounds.height) * 0.4
        guard pin != optionsArePinned else { return }
        optionsArePinned = pin
        optionStack.removeFromSuperview()
        cancelButton.removeFromSuperview()
        // Unpinned, the empty footer goes and the scrolling area runs to the sheet's edge.
        pinned.isHidden = !pin
        scrollAbovePinned?.isActive = pin
        scrollToEdge?.isActive = !pin
        contentBottom?.constant = pin ? -4 : -Self.bottomInset
        if pin {
            pinned.addArrangedSubview(optionStack)
            pinned.addArrangedSubview(cancelButton)
        } else {
            let last = content.arrangedSubviews.last
            content.addArrangedSubview(optionStack)
            content.addArrangedSubview(cancelButton)
            if let last { content.setCustomSpacing(20, after: last) }
            content.setCustomSpacing(10, after: optionStack)
        }
        view.setNeedsLayout()
        // Said once it is there: the options are further down.
        if !pin, view.window != nil { scrollView.flashScrollIndicators() }
    }

    private static let bottomInset: CGFloat = 16

    /// The height that shows everything without scrolling, above the bottom safe area.
    var fittingHeight: CGFloat {
        loadViewIfNeeded()
        guard optionsArePinned else { return ceil(Self.topInset + height(of: content) + Self.bottomInset) }
        return ceil(Self.topInset + height(of: content) + 4 + 12 + height(of: pinned) + 12)
    }

    /// The column's width: the readable width, at least 20 points in from each edge.
    private var columnWidth: CGFloat {
        let width = view.bounds.width > 0 ? view.bounds.width : 390
        let readable = view.readableContentGuide.layoutFrame.width
        return max(0, min(width - 40, readable > 0 ? readable : width))
    }

    private func height(of subview: UIView) -> CGFloat {
        subview.systemLayoutSizeFitting(CGSize(width: columnWidth, height: UIView.layoutFittingCompressedSize.height),
                                        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollView.flashScrollIndicators()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { onDismissedElsewhere?() }
    }

    /// Escape cancels, as on the Mac. No key chooses an option.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Cancel Request", action: #selector(cancelFromKeyboard), input: UIKeyCommand.inputEscape)]
    }

    @objc private func cancelFromKeyboard() { finish(nil) }

    override func accessibilityPerformEscape() -> Bool {
        finish(nil)
        return true
    }

    /// The decision, once. Dismissal follows from the queue moving on.
    func finish(_ optionID: String?) {
        guard !decided else { return }
        decided = true
        decide(optionID)
    }
}
