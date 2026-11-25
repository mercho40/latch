import AppKit

/// Open With for a workspace on this Mac: whatever applications say they open a folder, such
/// as an editor, so Latch names none of them. Finder and Terminal have items of their own.
@MainActor
enum WorkspaceApplications {
    private static let excluded: Set<String> = ["com.apple.finder", "com.apple.Terminal"]

    /// The applications that open `folder`, by name.
    static func applications(for folder: URL, workspace: NSWorkspace = .shared) -> [URL] {
        let own = Bundle.main.bundleURL.standardizedFileURL
        var seen = Set<String>()
        return workspace.urlsForApplications(toOpen: folder)
            .filter { url in
                let id = Bundle(url: url)?.bundleIdentifier ?? url.path
                return !excluded.contains(id) && url.standardizedFileURL != own && seen.insert(id).inserted
            }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    /// Fills `menu` with an item per application, each opening `folder` in it.
    static func fill(_ menu: NSMenu, for folder: URL?, workspace: NSWorkspace = .shared) {
        menu.removeAllItems()
        let applications = folder.map { applications(for: $0, workspace: workspace) } ?? []
        guard let folder, !applications.isEmpty else {
            menu.addItem(withTitle: "No Applications", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for application in applications {
            let item = NSMenuItem(title: name(of: application), action: #selector(Opener.open(_:)), keyEquivalent: "")
            item.target = Opener.shared
            item.representedObject = Opener.Request(folder: folder, application: application)
            let icon = workspace.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
    }

    private static func name(of application: URL) -> String {
        FileManager.default.displayName(atPath: application.path).replacingOccurrences(of: ".app", with: "")
    }

    @MainActor
    final class Opener: NSObject {
        static let shared = Opener()

        final class Request: NSObject {
            let folder: URL
            let application: URL
            init(folder: URL, application: URL) {
                self.folder = folder
                self.application = application
            }
        }

        @objc func open(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? Request else { return }
            NSWorkspace.shared.open([request.folder], withApplicationAt: request.application,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// An Open With submenu filled when it opens, for the folder `folder` gives at that moment.
@MainActor
final class WorkspaceApplicationsMenu: NSMenu, NSMenuDelegate {
    private let folder: () -> URL?

    init(title: String, folder: @escaping () -> URL?) {
        self.folder = folder
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("Not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        WorkspaceApplications.fill(menu, for: folder())
    }
}
