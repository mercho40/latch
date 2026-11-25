import AppKit
import LatchSessionKit

/// Whether a server answers, the same wherever it is shown: Settings ▸ Servers, from a check,
/// and the sidebar's server groups, from the sessions on it. Colour only for what changes
/// what the user does next, as in the session rows: a server not yet heard from is grey.
enum ServerStatus: Equatable {
    case checking, connected, reconnecting, failed

    var color: NSColor {
        switch self {
        case .checking: .tertiaryLabelColor
        case .connected: .systemGreen
        case .reconnecting: .systemOrange
        case .failed: .systemRed
        }
    }

    /// With Differentiate Without Color on, a shape says it too.
    var symbol: String {
        switch self {
        case .checking: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var words: String {
        switch self {
        case .checking: "Checking…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed: "Can’t connect"
        }
    }

    /// The server's state as the sessions on it see it, or nil when none is connected or trying:
    /// a sidebar says nothing about a server it has not tried to reach. A live outage outranks a
    /// working link, which outranks an old failure that a session left behind.
    @MainActor
    static func of(_ sessions: [SessionViewController]) -> (status: ServerStatus, detail: String?)? {
        var connected = false
        var failure: String?
        for session in sessions {
            let model = session.model
            if model.isRetryingLink { return (.reconnecting, nil) }
            if case let .failed(_, reason, runtimeGone) = model.linkState, !runtimeGone { failure = failure ?? reason }
            if model.phase == .disconnected, model.errorIsConnectionFailure { failure = failure ?? model.errorMessage }
            if [.ready, .prompting, .stopping].contains(model.phase), model.linkState == .connected { connected = true }
        }
        if connected { return (.connected, nil) }
        return failure.map { (.failed, $0) }
    }
}

/// A dot in a status's colour, sized to sit beside a line of small text; with Differentiate
/// Without Color on, a symbol whose shape says the status as well.
@MainActor
final class ServerStatusDot: NSImageView {
    var status: ServerStatus? {
        didSet { redraw() }
    }

    private func redraw() {
        isHidden = status == nil
        contentTintColor = status?.color
        let shapes = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        image = NSImage(systemSymbolName: shapes ? status?.symbol ?? "circle.fill" : "circle.fill", accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: shapes ? 9 : 7, weight: .regular)
    }

    @objc private func displayOptionsChanged() { redraw() }

    init() {
        super.init(frame: .zero)
        redraw()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        imageScaling = .scaleProportionallyDown
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // Its words go with the row it sits in, so it is not announced on its own.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
}
