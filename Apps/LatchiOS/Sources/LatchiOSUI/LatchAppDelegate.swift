import UIKit

/// The application delegate `main.swift` names. Everything with a window lives in the
/// scene: this says which delegate class each new scene gets, and what the menu bar offers,
/// which on iPadOS 26 is the menu bar and before it the list a held ⌘ shows.
public final class LatchAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(_ application: UIApplication,
                            configurationForConnecting connectingSceneSession: UISceneSession,
                            options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LatchSceneDelegate.self
        return configuration
    }

    /// The Mac's menus where iPadOS has a place for them: New Session in File, Servers where
    /// Settings goes, a Session menu for the open session, and Jump to Latest in View. Every
    /// item is a command the responder chain answers, so an item that does not apply is
    /// dimmed. Format and Toolbar, which nothing here uses, are left out.
    public override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        builder.remove(menu: .toolbar)

        let servers = UIKeyCommand(title: "Servers…", image: UIImage(systemName: "server.rack"),
                                   action: #selector(RootViewController.serversCommand), input: ",", modifierFlags: .command)
        let serversMenu = UIMenu(options: .displayInline, children: [servers])
        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: serversMenu)
        } else {
            builder.insertSibling(serversMenu, afterMenu: .about)
        }

        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "New Session…", image: UIImage(systemName: "plus"),
                         action: #selector(RootViewController.newSessionCommand), input: "n", modifierFlags: .command),
        ]), atStartOfMenu: .file)

        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Jump to Latest", image: UIImage(systemName: "arrow.down"),
                         action: #selector(SessionDetailViewController.jumpToLatestCommand),
                         input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
        ]), atEndOfMenu: .view)

        builder.insertSibling(Self.sessionMenu, afterMenu: .view)
    }

    static let sessionMenuIdentifier = UIMenu.Identifier("dev.latchapp.ios.session")

    /// Send and Stop, the composer's photos, the session's own commands, then moving between
    /// sessions with the Mac's keys; ⌘[ and ⌘], which the app had first, still work unlisted.
    static var sessionMenu: UIMenu {
        func command(_ title: String, _ symbol: String?, _ action: Selector, _ input: String? = nil,
                     _ modifiers: UIKeyModifierFlags = .command, priority: Bool = false,
                     attributes: UIMenuElement.Attributes = [], variant: String? = nil) -> UICommand {
            guard let input else {
                return UICommand(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, action: action,
                                 attributes: attributes)
            }
            // A second key for one action is told apart by its property list, as UIKit requires.
            let key = UIKeyCommand(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, action: action,
                                   input: input, modifierFlags: modifiers, propertyList: variant, attributes: attributes)
            // Over the composer's own handling of the keys, which would type or move the cursor.
            key.wantsPriorityOverSystemBehavior = priority
            return key
        }
        let session = SessionDetailViewController.self
        let root = RootViewController.self
        return UIMenu(title: "Session", identifier: sessionMenuIdentifier, children: [
            UIMenu(options: .displayInline, children: [
                command("Send", "arrow.up.circle", #selector(session.sendCommand), "\r", priority: true),
                command("Stop", "stop.circle", #selector(session.stopCommand), ".", priority: true),
                command("Add Photos…", "photo.on.rectangle", #selector(session.addPhotosCommand), "a", [.command, .shift]),
            ]),
            UIMenu(options: .displayInline, children: [
                command("Rename…", "pencil", #selector(session.renameCommand)),
                // Finder's Copy as Pathname.
                command("Copy Path", "doc.on.doc", #selector(session.copyPathCommand), "c", [.command, .alternate]),
            ]),
            UIMenu(options: .displayInline, children: [
                command("Start Agent", "play.circle", #selector(session.startAgentCommand)),
                command("Stop Agent…", "stop.circle", #selector(session.stopAgentCommand), attributes: .destructive),
            ]),
            UIMenu(options: .displayInline, children: [
                command("Previous Session", "chevron.up", #selector(root.previousSessionCommand),
                        UIKeyCommand.inputUpArrow, [.command, .alternate]),
                command("Next Session", "chevron.down", #selector(root.nextSessionCommand),
                        UIKeyCommand.inputDownArrow, [.command, .alternate]),
                command("Previous Session", nil, #selector(root.previousSessionCommand), "[", attributes: .hidden, variant: "bracket"),
                command("Next Session", nil, #selector(root.nextSessionCommand), "]", attributes: .hidden, variant: "bracket"),
            ]),
        ])
    }
}
