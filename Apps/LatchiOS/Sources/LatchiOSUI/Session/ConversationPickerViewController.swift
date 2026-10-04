import LatchACP
import UIKit

/// The agent's saved conversations in the session's folder, newest first, each by its title and
/// when it last changed, for a session with nothing in it yet to take one up. Claude Code's
/// include those started on its command line. Choosing one hands it to `onChoose`.
final class ConversationPickerViewController: UITableViewController {
    let conversations: [ACPSessionSummary]
    var onChoose: ((ACPSessionSummary) -> Void)?
    var onCancel: (() -> Void)?
    private let agentTitle: String
    private let folder: String
    private static let cell = "conversation"

    init(conversations: [ACPSessionSummary], agentTitle: String, folder: String) {
        self.conversations = Self.newestFirst(conversations)
        self.agentTitle = agentTitle
        self.folder = folder
        super.init(style: .insetGrouped)
        title = "Resume Conversation"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onCancel?()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In a sheet as New Session is: half the height on iPhone, or all of it at accessibility
    /// sizes, and a form sheet on iPad.
    func inSheet(compact: Bool, accessibilitySize: Bool) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        if !compact {
            navigation.modalPresentationStyle = .formSheet
            navigation.preferredContentSize = CGSize(width: 540, height: 480)
        } else if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            if accessibilitySize { sheet.selectedDetentIdentifier = .large }
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cell)
        guard conversations.isEmpty else { return }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "clock.arrow.circlepath")
        empty.text = "No Conversations to Resume"
        empty.secondaryText = "\(agentTitle) has no other saved conversations in \(folder.isEmpty ? "this folder" : folder)."
        contentUnavailableConfiguration = empty
    }

    override func numberOfSections(in tableView: UITableView) -> Int { conversations.isEmpty ? 0 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { conversations.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cell, for: indexPath)
        let conversation = conversations[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = Self.title(of: conversation)
        content.secondaryText = Self.date(of: conversation)?.formatted(date: .abbreviated, time: .shortened)
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 3
        content.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = content
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "\(agentTitle)’s saved conversations in \(folder.isEmpty ? "this folder" : folder). "
            + "The one you choose goes on in this session, with its history."
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onChoose?(conversations[indexPath.row])
    }

    /// Its title, at most a few lines of it, or "Untitled Conversation" without one.
    static func title(of conversation: ACPSessionSummary) -> String {
        let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled Conversation" : String(title.prefix(200))
    }

    /// By when each last changed, newest first; those without a date last, in the agent's order.
    static func newestFirst(_ conversations: [ACPSessionSummary]) -> [ACPSessionSummary] {
        conversations.enumerated().sorted { a, b in
            switch (date(of: a.element), date(of: b.element)) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// When it last changed, from the agent's ISO 8601, with or without fractions of a second,
    /// in whichever time zone it was written.
    static func date(of conversation: ACPSessionSummary) -> Date? {
        guard let text = conversation.updatedAt else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
