import UIKit

/// What the agent's permission requests and questions share as sheets. What is asked always
/// comes first, in a scrolling area, and the buttons that answer it, Cancel Request last, stay
/// pinned below it only while they leave most of the sheet to it; when they would not, as at
/// accessibility text sizes, all of them follow what is asked in the scrolling area, together,
/// so nobody answers without having scrolled past it, and Cancel is never the only choice in
/// sight. The sheet is as tall as it needs, or the whole height, and cannot be swiped away:
/// it closes with an answer, or on its own when the request does.
///
/// A subclass fills `content` and `actions` in `viewDidLoad`, then calls `installSheetLayout()`.
class RequestSheetViewController: UIViewController {
    static let fitDetent = UISheetPresentationController.Detent.Identifier("fit")

    /// What is asked, top to bottom.
    let content = UIStackView()
    /// The buttons that answer it.
    let actions = UIStackView()
    let scrollView = UIScrollView()
    private let pinned = UIStackView()
    private let heading = UIStackView()
    /// The scrolling area ends above the pinned buttons, or with them inside it, at the sheet's edge.
    private var scrollAbovePinned: NSLayoutConstraint?
    private var scrollToEdge: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?
    /// Whether the buttons are pinned below what is asked, or follow it inside the scrolling area.
    private(set) var actionsArePinned = true
    /// Called when the sheet goes without an answer or a closed request taking it down.
    var onDismissedElsewhere: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
        // A centred form on an iPad; a sheet from the bottom on an iPhone.
        modalPresentationStyle = .formSheet
        if let sheet = sheetPresentationController {
            // As tall as what is asked needs, or the whole height.
            sheet.detents = [.custom(identifier: Self.fitDetent) { [weak self] context in
                self.map { min($0.fittingHeight, context.maximumDetentValue) }
            }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet's first row: the list's mark for something waiting on the user, and who asks,
    /// such as "Claude Code requests permission". The title under it says it for VoiceOver.
    func headingRow(symbol: String, tint: UIColor, caption text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = tint
        icon.preferredSymbolConfiguration = .init(textStyle: .title2)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        // At accessibility sizes the heading grows less than what is asked, so the buttons come
        // into view sooner.
        icon.maximumContentSizeCategory = .accessibilityMedium

        let caption = UILabel()
        caption.text = text
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.maximumContentSizeCategory = .accessibilityMedium
        caption.isAccessibilityElement = false

        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(caption)
        heading.spacing = 8
        return heading
    }

    /// A line of the sheet's own advice, after what is asked, such as who keeps an "Always".
    static func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    func installSheetLayout() {
        view.backgroundColor = .systemBackground
        content.axis = .vertical
        content.spacing = 16
        actions.axis = .vertical
        actions.spacing = 10
        pinned.axis = .vertical
        pinned.addArrangedSubview(actions)

        scrollView.alwaysBounceVertical = false
        scrollView.keyboardDismissMode = .interactive
        for view in [content, pinned, scrollView] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        scrollView.addSubview(content)
        view.addSubview(scrollView)
        view.addSubview(pinned)
        let guide = view.readableContentGuide
        // Without a keyboard the guide's top is the sheet's bottom edge, under the safe area.
        let keyboard = view.keyboardLayoutGuide
        keyboard.usesBottomSafeArea = false
        let abovePinned = scrollView.bottomAnchor.constraint(equalTo: pinned.topAnchor, constant: -12)
        let bottom = content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4)
        let atSafeArea = pinned.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        atSafeArea.priority = .defaultHigh
        scrollAbovePinned = abovePinned
        scrollToEdge = scrollView.bottomAnchor.constraint(equalTo: keyboard.topAnchor)
        contentBottom = bottom
        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            abovePinned,
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Self.topInset),
            bottom,
            // Above the safe area, and above the keyboard while one is up.
            atSafeArea,
            pinned.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            pinned.bottomAnchor.constraint(lessThanOrEqualTo: keyboard.topAnchor, constant: -12),
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
        // What scrolls under the pinned buttons fades into them rather than stopping at a hard line.
        if #available(iOS 26.0, *) {
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = scrollView
            edge.edge = .bottom
            pinned.addInteraction(edge)
            scrollView.bottomEdgeEffect.style = .soft
        }
        arrangeHeading()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: RequestSheetViewController, _) in
            controller.arrangeHeading()
            controller.sheetPresentationController?.invalidateDetents()
        }
    }

    private static let topInset: CGFloat = 28
    private static let bottomInset: CGFloat = 16

    /// At accessibility sizes the mark goes above the caption, so the caption keeps its width.
    private func arrangeHeading() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        heading.axis = large ? .vertical : .horizontal
        heading.alignment = large ? .leading : .center
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        prepare(width: columnWidth)
        // Pinned only while the buttons leave what is asked most of the sheet at its tallest.
        // Measured against the window, not this sheet, whose height follows the choice.
        // Measured, not read from frames, which this pass has not yet set below the top level.
        guard view.bounds.height > 0 else { return }
        let pin = height(of: actions) <= (view.window?.bounds.height ?? view.bounds.height) * 0.4
        guard pin != actionsArePinned else { return }
        actionsArePinned = pin
        actions.removeFromSuperview()
        // Unpinned, the empty footer goes and the scrolling area runs to the sheet's edge.
        pinned.isHidden = !pin
        scrollAbovePinned?.isActive = pin
        scrollToEdge?.isActive = !pin
        contentBottom?.constant = pin ? -4 : -Self.bottomInset
        if pin {
            pinned.addArrangedSubview(actions)
        } else {
            let last = content.arrangedSubviews.last
            content.addArrangedSubview(actions)
            if let last { content.setCustomSpacing(20, after: last) }
        }
        view.setNeedsLayout()
        // Said once it is there: the buttons are further down.
        if !pin, view.window != nil { scrollView.flashScrollIndicators() }
    }

    /// Sizes anything laid out by hand, such as Markdown, for the column's `width`, before the
    /// sheet is measured or laid out.
    func prepare(width: CGFloat) {}

    /// The height that shows everything without scrolling, above the bottom safe area.
    var fittingHeight: CGFloat {
        loadViewIfNeeded()
        prepare(width: columnWidth)
        guard actionsArePinned else { return ceil(Self.topInset + height(of: content) + Self.bottomInset) }
        return ceil(Self.topInset + height(of: content) + 4 + 12 + height(of: pinned) + 12)
    }

    /// The column's width: the readable width, at least 20 points in from each edge.
    var columnWidth: CGFloat {
        let width = view.bounds.width > 0 ? view.bounds.width : 390
        let readable = view.readableContentGuide.layoutFrame.width
        return max(0, min(width - 40, readable > 0 ? readable : width))
    }

    private func height(of subview: UIView) -> CGFloat {
        subview.systemLayoutSizeFitting(CGSize(width: columnWidth, height: UIView.layoutFittingCompressedSize.height),
                                        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    /// What VoiceOver's focus goes to when the sheet arrives: what is asked.
    var firstFocus: Any? { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollView.flashScrollIndicators()
        UIAccessibility.post(notification: .screenChanged, argument: firstFocus)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { onDismissedElsewhere?() }
    }

    /// Escape cancels, as on the Mac.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Cancel Request", action: #selector(cancelFromKeyboard), input: UIKeyCommand.inputEscape)]
    }

    @objc private func cancelFromKeyboard() { cancelRequest() }

    override func accessibilityPerformEscape() -> Bool {
        cancelRequest()
        return true
    }

    /// Cancel Request, from its button, Escape or VoiceOver's escape gesture.
    func cancelRequest() {}
}
