import SwiftUI
import UniformTypeIdentifiers
import WinlinkKit

struct MailboxView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var settings: AppSettings
    @State private var composing: ComposeDraft?
    @State private var reportingPosition = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(Folder.allCases) { f in
                    NavigationLink(value: f) {
                        HStack {
                            Label(f.rawValue, systemImage: f.symbol)
                            Spacer()
                            let n = f == .inbox ? store.unreadCount : store.list(f).count
                            if n > 0 {
                                Text("\(n)").foregroundStyle(f == .inbox ? Color.accentColor : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mailboxes")
            .navigationDestination(for: Folder.self) { FolderView(folder: $0, composing: $composing) }
            .navigationDestination(for: StoredMessage.self) { MessageView(stored: $0, composing: $composing) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = ComposeDraft() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New message")
                }
                ToolbarItem(placement: .automatic) {
                    Button { reportingPosition = true } label: { Image(systemName: "mappin.and.ellipse") }
                        .accessibilityLabel("Position report")
                }
            }
            .sheet(item: $composing) { ComposeView(draft: $0) }
            .sheet(isPresented: $reportingPosition) { PositionReportView() }
        }
    }
}

struct FolderView: View {
    @EnvironmentObject var store: MailStore
    let folder: Folder
    @Binding var composing: ComposeDraft?

    var body: some View {
        List {
            ForEach(store.list(folder)) { s in
                NavigationLink(value: s) { MessageRow(stored: s) }
            }
            .onDelete { idx in
                for i in idx { store.delete(store.list(folder)[i]) }
            }
        }
        .overlay {
            if store.list(folder).isEmpty {
                ContentUnavailableView("No messages", systemImage: folder.symbol,
                                       description: Text(folder == .outbox ? "Messages you write wait here until the next connection." : ""))
            }
        }
        .navigationTitle(folder.rawValue)
        .refreshable { store.reload() }
    }
}

struct MessageRow: View {
    let stored: StoredMessage
    var body: some View {
        let m = stored.message
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if stored.unread { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
                Text(stored.folder == .inbox ? m.from.addr : m.receivers.map(\.addr).joined(separator: ", "))
                    .font(.headline).lineLimit(1)
                Spacer()
                if let d = m.date { Text(d, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                if !m.files.isEmpty { Image(systemName: "paperclip").font(.caption) }
                Text(m.subject).font(.subheadline).lineLimit(1)
            }
            Text(m.bodyText.replacingOccurrences(of: "\r\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct MessageView: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) var dismiss
    let stored: StoredMessage
    @Binding var composing: ComposeDraft?

    var body: some View {
        let m = stored.message
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(m.subject).font(.title3).bold()
                Group {
                    LabeledContent("From", value: m.from.addr)
                    if !m.to.isEmpty { LabeledContent("To", value: m.to.map(\.addr).joined(separator: ", ")) }
                    if !m.cc.isEmpty { LabeledContent("Cc", value: m.cc.map(\.addr).joined(separator: ", ")) }
                    if let d = m.date { LabeledContent("Date", value: d.formatted(date: .abbreviated, time: .shortened)) }
                    LabeledContent("MID", value: m.mid)
                }
                .font(.footnote)
                Divider()
                Text(m.bodyText.replacingOccurrences(of: "\r\n", with: "\n"))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                if !m.files.isEmpty {
                    Divider()
                    ForEach(m.files, id: \.name) { f in
                        AttachmentRow(file: f)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inlineTitle()
        .onAppear { store.markRead(stored) }
        .toolbar {
            ToolbarItemGroup(placement: .messageActions) {
                Button { composing = .reply(to: m, all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { composing = .reply(to: m, all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
                Button { composing = .forward(m) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                Spacer()
                if stored.folder == .outbox || stored.folder == .drafts {
                    Button { composing = .edit(stored) } label: { Label("Edit", systemImage: "pencil") }
                }
                Button(role: .destructive) {
                    store.delete(stored)
                    dismiss()
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

struct AttachmentRow: View {
    let file: Attachment
    var body: some View {
        HStack {
            Image(systemName: "doc")
            Text(file.name).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)).foregroundStyle(.secondary)
            Spacer()
            if let url = temporaryCopy() {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .font(.footnote)
    }

    private func temporaryCopy() -> URL? {
        let safe = file.name.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        return (try? file.data.write(to: url)) != nil ? url : nil
    }
}

// MARK: - Compose

struct ComposeDraft: Identifiable {
    let id = UUID()
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var files: [Attachment] = []
    var replacing: StoredMessage?

    static func reply(to m: Message, all: Bool) -> ComposeDraft {
        var d = ComposeDraft()
        d.to = m.from.addr
        if all {
            d.cc = (m.to + m.cc).map(\.addr).joined(separator: ", ")
        }
        d.subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: " + m.subject
        d.body = "\n\n" + quote(m)
        return d
    }

    static func forward(_ m: Message) -> ComposeDraft {
        var d = ComposeDraft()
        d.subject = m.subject.lowercased().hasPrefix("fw:") ? m.subject : "Fw: " + m.subject
        d.body = "\n\n---------- Forwarded message ----------\nFrom: \(m.from.addr)\nSubject: \(m.subject)\n\n" +
            m.bodyText.replacingOccurrences(of: "\r\n", with: "\n")
        d.files = m.files
        return d
    }

    static func edit(_ s: StoredMessage) -> ComposeDraft {
        let m = s.message
        var d = ComposeDraft()
        d.to = m.to.map(\.addr).joined(separator: ", ")
        d.cc = m.cc.map(\.addr).joined(separator: ", ")
        d.subject = m.subject
        d.body = m.bodyText.replacingOccurrences(of: "\r\n", with: "\n")
        d.files = m.files
        d.replacing = s
        return d
    }

    private static func quote(_ m: Message) -> String {
        let when = m.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        let lines = m.bodyText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return "On \(when), \(m.from.addr) wrote:\n" + lines.map { "> " + $0 }.joined(separator: "\n")
    }
}

struct ComposeView: View {
    @EnvironmentObject var store: MailStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State var draft: ComposeDraft
    @State private var importing = false
    @State private var error: String?

    /// Attachments travel at a few hundred bytes per second on HF; warn well before they hurt.
    private let sizeWarning = 30_000

    init(draft: ComposeDraft) { _draft = State(initialValue: draft) }

    private var totalSize: Int { draft.body.utf8.count + draft.files.reduce(0) { $0 + $1.data.count } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To (call sign or email)", text: $draft.to)
                        .input(.email)
                    TextField("Cc", text: $draft.cc)
                        .input(.email)
                    TextField("Subject", text: $draft.subject)
                }
                Section {
                    TextEditor(text: $draft.body).frame(minHeight: 220).font(.body.monospaced())
                }
                Section {
                    ForEach(draft.files, id: \.name) { f in
                        HStack {
                            Image(systemName: "paperclip")
                            Text(f.name).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(f.data.count), countStyle: .file)).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { draft.files.remove(atOffsets: $0) }
                    Button { importing = true } label: { Label("Attach file", systemImage: "paperclip") }
                } footer: {
                    if totalSize > sizeWarning {
                        Text("This message is \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)). Over HF that can take many minutes.")
                            .foregroundStyle(.orange)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .groupedForm()
            .navigationTitle(draft.replacing == nil ? "New Message" : "Edit Message")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post(to: .outbox) }.bold()
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save draft") { post(to: .drafts) }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                for u in urls {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: u) {
                        draft.files.append(Attachment(name: u.lastPathComponent, data: d))
                    }
                }
            }
        }
    }

    private static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    /// Queues the message in the Outbox (or Drafts); it goes out on the next connection.
    private func post(to folder: Folder) {
        guard !settings.mycall.isEmpty else {
            error = "Set your call sign in Settings first."
            return
        }
        var m = Message(from: settings.mycall)
        m.addTo(Self.split(draft.to))
        m.addCc(Self.split(draft.cc))
        m.subject = draft.subject.trimmingCharacters(in: .whitespaces)
        m.setBody(draft.body.isEmpty ? " " : draft.body)
        for f in draft.files { m.addFile(f) }
        if folder == .outbox {
            do {
                try m.validate()
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        do {
            if let old = draft.replacing { store.delete(old) }
            try store.save(m, to: folder)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
