import AppKit
import LatchAgentCore
import LatchSessionKit

/// Where sessions were started, on this Mac and on servers, newest first. Open Recent, the
/// toolbar's New Session menu, the empty window and the New Remote Session sheet read it.
/// The system's recent documents can hold only file URLs, so a folder on a server is kept
/// here; folders on this Mac are noted in both.
@MainActor
final class RecentWorkspaces {
    struct Entry: Codable, Equatable {
        var path: String
        /// Nil for a folder on this Mac.
        var serverID: UUID?
        /// The agent a session there last started on: kept for a server's folders only, since a
        /// session on this Mac starts on the agent Settings suggests.
        var agent: String?
        var date: Date

        var location: WorkspaceLocation {
            serverID.map { .remote(serverID: $0, path: path) } ?? .local(URL(fileURLWithPath: path))
        }
    }

    static let defaultsKey = "LatchRecentWorkspaces"
    /// Set from seeding until a launch has restored its sessions, so a launch that failed to
    /// load them leaves the adopting to the next.
    static let adoptPendingKey = "LatchRecentWorkspacesAdoptPending"
    static let capacity = 10

    /// Nil keeps the list in memory, as tests and smoke runs do.
    private let defaults: UserDefaults?
    private(set) var entries: [Entry]
    /// Set by the launch that first seeded the list, so the places open in the sidebar join it
    /// once; later launches leave a cleared list cleared.
    private(set) var adoptsOpenPlaces: Bool

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        // Data that cannot be read starts an empty list rather than reseeding over it.
        entries = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        adoptsOpenPlaces = defaults?.bool(forKey: Self.adoptPendingKey) ?? false
    }

    /// A session was started here: it moves to the top.
    func note(_ location: WorkspaceLocation, agent: AgentPreset?, at date: Date = Date()) {
        let key = location.groupKey
        entries.removeAll { $0.location.groupKey == key }
        entries.insert(Entry(path: key.path, serverID: key.serverID, agent: key.isRemote ? agent?.rawValue : nil,
                             date: date), at: 0)
        entries = Array(entries.prefix(Self.capacity))
        save()
    }

    /// A place already open in the sidebar, added where its date puts it. One already listed
    /// moves only if it was used later than the list says, as a seeded folder always was.
    func adopt(_ location: WorkspaceLocation, agent: AgentPreset?, lastActive: Date?) {
        let key = location.groupKey
        let date = lastActive ?? .distantPast
        var agentID = key.isRemote ? agent?.rawValue : nil
        if let index = entries.firstIndex(where: { $0.location.groupKey == key }) {
            guard entries[index].date < date else { return }
            agentID = agentID ?? entries[index].agent
            entries.remove(at: index)
        }
        let entry = Entry(path: key.path, serverID: key.serverID, agent: agentID, date: date)
        entries.insert(entry, at: entries.firstIndex { $0.date < date } ?? entries.endIndex)
        entries = Array(entries.prefix(Self.capacity))
        save()
    }

    /// Takes over the folders the system remembers, the first time the list is kept at all.
    /// The system keeps their order but no dates, so they rank below every place that has one
    /// and are the first to go when the places open in the sidebar join the list.
    func seedIfNeeded(from urls: [URL]) {
        guard let defaults, defaults.object(forKey: Self.defaultsKey) == nil else { return }
        var seen: Set<WorkspaceLocation> = []
        entries = urls.filter(\.isFileURL).compactMap { url -> WorkspaceLocation? in
            let key = WorkspaceLocation.local(url).groupKey
            return seen.insert(key).inserted ? key : nil
        }.prefix(Self.capacity).enumerated().map { index, key in
            Entry(path: key.path, serverID: nil, agent: nil, date: Date.distantPast.addingTimeInterval(-Double(index)))
        }
        adoptsOpenPlaces = true
        defaults.set(true, forKey: Self.adoptPendingKey)
        save()
    }

    func finishAdopting() {
        adoptsOpenPlaces = false
        defaults?.removeObject(forKey: Self.adoptPendingKey)
    }

    func clear() {
        entries = []
        finishAdopting()
        save()
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// The places worth offering, in order: a folder on this Mac that still exists, or one on a
    /// server that is still set up. A removed server's places are skipped rather than deleted,
    /// since a servers file that could not be read also lists no servers.
    static func places(_ entries: [Entry], serverName: (UUID) -> String?, limit: Int) -> [RecentPlace] {
        var places: [RecentPlace] = []
        for entry in entries where places.count < limit {
            if let serverID = entry.serverID {
                guard let server = serverName(serverID) else { continue }
                places.append(RecentPlace(location: entry.location, agent: entry.agent.flatMap(AgentPreset.init(rawValue:)),
                                          server: server))
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                places.append(RecentPlace(location: entry.location, agent: nil, server: nil))
            }
        }
        return places
    }
}

/// One recent place as the menus and the empty window show it, named as its sidebar group is.
struct RecentPlace: Equatable {
    let location: WorkspaceLocation
    /// The agent to start a session on a server's folder with; nil on this Mac.
    let agent: AgentPreset?
    let title: String
    /// Where the folder is: its parent, so two folders of one name tell apart.
    let detail: String
    let tooltip: String
    let accessibilityLabel: String

    init(location: WorkspaceLocation, agent: AgentPreset?, server: String?) {
        self.location = location
        self.agent = agent
        let group = SidebarViewController.groupTitle(location) { _ in server }
        title = group.name
        tooltip = group.tooltip
        if let url = location.localURL {
            detail = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            accessibilityLabel = "Start a session in \(location.folderName)"
        } else {
            let parent = (location.path as NSString).deletingLastPathComponent
            detail = parent == location.path ? "" : parent
            accessibilityLabel = "Start a session in \(location.folderName) on \(server ?? "a server")"
        }
    }

    var icon: NSImage {
        if let url = location.localURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server") ?? NSImage()
    }

    /// No key equivalent: a menu a control owns would perform it ahead of the main menu.
    func menuItem(action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.subtitle = detail.isEmpty ? nil : detail
        item.toolTip = tooltip
        item.representedObject = RecentPlaceBox(self)
        let image = icon.copy() as? NSImage ?? icon
        image.size = NSSize(width: 16, height: 16)
        item.image = image
        return item
    }
}

/// A menu item's represented object, so the place comes back whole whatever bridges it.
final class RecentPlaceBox: NSObject {
    let place: RecentPlace
    init(_ place: RecentPlace) { self.place = place }
}
