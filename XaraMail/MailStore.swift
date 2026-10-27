import Foundation
import WinlinkKit

enum Folder: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case outbox = "Outbox"
    case sent = "Sent"
    case drafts = "Drafts"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .outbox: return "tray.and.arrow.up"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        }
    }
}

struct StoredMessage: Identifiable, Hashable {
    let folder: Folder
    let message: Message
    var id: String { folder.rawValue + "/" + message.mid }
    var unread: Bool
}

/// Messages as raw B2F files, one directory per folder, under Application Support/Mail.
@MainActor
final class MailStore: ObservableObject {
    @Published private(set) var messages: [Folder: [StoredMessage]] = [:]
    nonisolated let root: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mail")
        self.root = base
        for f in Folder.allCases {
            try? FileManager.default.createDirectory(at: base.appendingPathComponent(f.rawValue), withIntermediateDirectories: true)
        }
        reload()
    }

    nonisolated func url(_ folder: Folder, _ mid: String) -> URL {
        root.appendingPathComponent(folder.rawValue).appendingPathComponent(mid + ".b2f")
    }

    private nonisolated var unreadURL: URL { root.appendingPathComponent("unread.txt") }

    private var unread: Set<String> {
        get { Set(((try? String(contentsOf: unreadURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)) }
        set { try? newValue.sorted().joined(separator: "\n").write(to: unreadURL, atomically: true, encoding: .utf8) }
    }

    func reload() {
        let unread = self.unread
        var out: [Folder: [StoredMessage]] = [:]
        for f in Folder.allCases {
            let dir = root.appendingPathComponent(f.rawValue)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            out[f] = files.filter { $0.pathExtension == "b2f" }.compactMap { u in
                guard let d = try? Data(contentsOf: u), let m = try? Message(parsing: Array(d)) else { return nil }
                return StoredMessage(folder: f, message: m, unread: f == .inbox && unread.contains(m.mid))
            }.sorted { ($0.message.date ?? .distantPast) > ($1.message.date ?? .distantPast) }
        }
        messages = out
    }

    func list(_ f: Folder) -> [StoredMessage] { messages[f] ?? [] }

    var unreadCount: Int { list(.inbox).filter(\.unread).count }

    func save(_ m: Message, to folder: Folder) throws {
        try Data(m.bytes()).write(to: url(folder, m.mid), options: .atomic)
        reload()
    }

    func delete(_ s: StoredMessage) {
        try? FileManager.default.removeItem(at: url(s.folder, s.message.mid))
        reload()
    }

    func move(_ s: StoredMessage, to folder: Folder) {
        try? FileManager.default.moveItem(at: url(s.folder, s.message.mid), to: url(folder, s.message.mid))
        reload()
    }

    func markRead(_ s: StoredMessage) {
        guard s.unread else { return }
        var u = unread
        u.remove(s.message.mid)
        unread = u
        reload()
    }

    nonisolated func markUnread(_ mid: String) {
        let u = unreadURL
        let cur = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        try? (cur.isEmpty ? mid : cur + "\n" + mid).write(to: u, atomically: true, encoding: .utf8)
    }

    /// A mailbox for one B2F session. It works on the files directly, since sessions run off the main actor.
    nonisolated func sessionMailbox(onChange: @escaping @Sendable () -> Void) -> SessionMailbox {
        SessionMailbox(store: self, onChange: onChange)
    }
}

final class SessionMailbox: Mailbox, @unchecked Sendable {
    private let store: MailStore
    private let onChange: @Sendable () -> Void

    init(store: MailStore, onChange: @escaping @Sendable () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    private func load(_ folder: Folder) -> [Message] {
        let dir = store.root.appendingPathComponent(folder.rawValue)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "b2f" }.compactMap {
            guard let d = try? Data(contentsOf: $0) else { return nil }
            return try? Message(parsing: Array(d))
        }
    }

    func outbound(for forwarders: [Address]) -> [Message] {
        let all = load(.outbox)
        // Through the CMS everything goes; to a P2P station only what is addressed to it.
        guard !forwarders.isEmpty else { return all }
        return all.filter { m in m.receivers.allSatisfy { r in forwarders.contains { $0.addr == r.addr } } }
    }

    func markSent(mid: String, rejected: Bool) {
        // A rejection means the remote already has it, so it counts as sent too.
        try? FileManager.default.moveItem(at: store.url(.outbox, mid), to: store.url(.sent, mid))
        onChange()
    }

    func markDeferred(mid: String) {}

    func answer(for proposal: Proposal) -> ProposalAnswer {
        FileManager.default.fileExists(atPath: store.url(.inbox, proposal.mid).path) ? .reject : .accept
    }

    func receive(_ message: Message) throws {
        try Data(message.bytes()).write(to: store.url(.inbox, message.mid), options: .atomic)
        store.markUnread(message.mid)
        onChange()
    }
}
