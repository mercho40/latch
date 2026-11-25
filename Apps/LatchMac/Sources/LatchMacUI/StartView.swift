import AppKit

/// What the detail pane shows with no session selected: the workspaces used recently, here and
/// on servers, one click from a new session each, and a way to choose another. The pane around
/// it also takes a folder dropped from the Finder.
@MainActor
final class StartView: NSView {
    nonisolated static let maximumRecents = 5
    private static let columnWidth: CGFloat = 400

    var onOpenPlace: ((RecentPlace) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onNewRemoteSession: (() -> Void)?
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "What should we build?")
    private let recents = NSStackView()
    private let choose = NSButton(title: "New Session…", target: nil, action: nil)
    /// Beside New Session…, once there is a server to start one on.
    private let chooseRemote = NSButton(title: "New Remote Session…", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Or drop a folder here from the Finder.")
    private(set) var shownRecents: [RecentPlace] = []
    private var shownOffersRemote = false
    private var loaded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The same voice and size as a new session's own heading.
        heading.font = .systemFont(ofSize: 26)
        heading.alignment = .center
        recents.orientation = .vertical
        recents.alignment = .leading
        recents.spacing = 2
        recents.setAccessibilityElement(true)
        recents.setAccessibilityRole(.group)
        recents.setAccessibilityLabel("Recent workspaces")
        choose.bezelStyle = .rounded
        choose.controlSize = .large
        choose.target = self
        choose.action = #selector(chooseFolder)
        choose.toolTip = "Choose a workspace folder (⌘N)"
        chooseRemote.bezelStyle = .rounded
        chooseRemote.controlSize = .large
        chooseRemote.target = self
        chooseRemote.action = #selector(newRemoteSession)
        chooseRemote.toolTip = "Choose a server and a folder on it (⌥⌘N)"
        chooseRemote.isHidden = true
        let buttons = NSStackView(views: [choose, chooseRemote])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        for view in [heading, recents, buttons, hint] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(28, after: heading)
        stack.setCustomSpacing(24, after: recents)
        stack.setCustomSpacing(12, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // A little above centre, where a centred block looks centred.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            recents.widthAnchor.constraint(equalToConstant: Self.columnWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// The places come from the recent list, which leaves out folders and servers that are gone.
    func reload(_ places: [RecentPlace], offersRemote: Bool) {
        guard !loaded || places != shownRecents || offersRemote != shownOffersRemote else { return }
        loaded = true
        shownRecents = places
        shownOffersRemote = offersRemote
        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for place in places.prefix(Self.maximumRecents) {
            let row = RecentWorkspaceRow(place: place) { [weak self] in self?.onOpenPlace?(place) }
            recents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recents.widthAnchor).isActive = true
        }
        recents.isHidden = places.isEmpty
        chooseRemote.isHidden = !offersRemote
        // With nothing recent, choosing a folder is the only way forward, so it takes Return.
        choose.keyEquivalent = places.isEmpty ? "\r" : ""
    }

    @objc private func chooseFolder() { onChooseFolder?() }

    @objc private func newRemoteSession() { onNewRemoteSession?() }
}

/// One recent workspace: its Finder icon, or a server's, its name, and where it is. Clicking
/// starts a session there.
@MainActor
private final class RecentWorkspaceRow: NSButton {
    private let open: () -> Void
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(place: RecentPlace, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        let icon = NSImageView(image: place.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        if place.location.isRemote {
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleNone
        }
        let name = NSTextField(labelWithString: place.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: place.detail)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.isHidden = place.detail.isEmpty
        for view in [icon, name, path] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [name, path] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            // A folder at the top of a server has no parent to show, so its name sits centred.
            place.detail.isEmpty ? name.centerYAnchor.constraint(equalTo: centerYAnchor)
                : name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            path.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        toolTip = place.tooltip
        setAccessibilityLabel(place.accessibilityLabel)
        setAccessibilityHelp(place.tooltip)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func fire() { open() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// A quiet fill under the pointer, and a stronger one while pressed. No animation: the
    /// highlight follows the pointer exactly.
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        guard hovered || pressed else { return }
        NSColor.labelColor.withAlphaComponent(pressed ? 0.1 : 0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
