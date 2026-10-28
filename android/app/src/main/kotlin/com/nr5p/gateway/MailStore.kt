package com.nr5p.gateway

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nr5p.winlink.Address
import com.nr5p.winlink.Mailbox
import com.nr5p.winlink.Message
import com.nr5p.winlink.Proposal
import com.nr5p.winlink.ProposalAnswer
import java.io.File
import java.time.Instant

enum class Folder(val title: String) {
    INBOX("Inbox"),
    OUTBOX("Outbox"),
    SENT("Sent"),
    DRAFTS("Drafts"),
}

data class StoredMessage(val folder: Folder, val message: Message, val unread: Boolean) {
    val id: String get() = folder.title + "/" + message.mid
}

/** Messages as raw B2F files, one directory per folder, under the app's files/Mail. */
class MailStore(val root: File) {
    var messages: Map<Folder, List<StoredMessage>> by mutableStateOf(emptyMap())
        private set

    init {
        for (f in Folder.entries) File(root, f.title).mkdirs()
        reload()
    }

    fun file(folder: Folder, mid: String) = File(File(root, folder.title), "$mid.b2f")

    private val unreadFile get() = File(root, "unread.txt")

    private var unread: Set<String>
        get() = synchronized(this) {
            if (unreadFile.exists()) unreadFile.readText().split("\n").filter { it.isNotEmpty() }.toSet() else emptySet()
        }
        set(v) = synchronized(this) { unreadFile.writeText(v.sorted().joinToString("\n")) }

    fun reload() {
        val unread = this.unread
        messages = Folder.entries.associateWith { f ->
            (File(root, f.title).listFiles() ?: emptyArray()).filter { it.extension == "b2f" }.mapNotNull { file ->
                val m = runCatching { Message.parse(file.readBytes()) }.getOrNull() ?: return@mapNotNull null
                StoredMessage(f, m, f == Folder.INBOX && m.mid in unread)
            }.sortedByDescending { it.message.date ?: Instant.EPOCH }
        }
    }

    fun list(f: Folder): List<StoredMessage> = messages[f] ?: emptyList()

    val unreadCount: Int get() = list(Folder.INBOX).count { it.unread }

    fun save(m: Message, folder: Folder) {
        val f = file(folder, m.mid)
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeBytes(m.bytes())
        tmp.renameTo(f)
        reload()
    }

    fun delete(s: StoredMessage) {
        file(s.folder, s.message.mid).delete()
        reload()
    }

    fun markRead(s: StoredMessage) {
        if (!s.unread) return
        unread = unread - s.message.mid
        reload()
    }

    fun markUnread(mid: String) {
        unread = unread + mid
    }

    /** A mailbox for one B2F session. It works on the files directly, since sessions run off the main thread. */
    fun sessionMailbox(onChange: () -> Unit): Mailbox = SessionMailbox(this, onChange)
}

private class SessionMailbox(private val store: MailStore, private val onChange: () -> Unit) : Mailbox {
    private fun load(folder: Folder): List<Message> =
        (File(store.root, folder.title).listFiles() ?: emptyArray()).filter { it.extension == "b2f" }
            .mapNotNull { runCatching { Message.parse(it.readBytes()) }.getOrNull() }

    override fun outbound(forwarders: List<Address>): List<Message> {
        val all = load(Folder.OUTBOX)
        // Through the CMS everything goes; to a P2P station only what is addressed to it.
        if (forwarders.isEmpty()) return all
        return all.filter { m -> m.receivers.all { r -> forwarders.any { it.addr == r.addr } } }
    }

    override fun markSent(mid: String, rejected: Boolean) {
        // A rejection means the remote already has it, so it counts as sent too.
        store.file(Folder.OUTBOX, mid).renameTo(store.file(Folder.SENT, mid))
        onChange()
    }

    override fun markDeferred(mid: String) {}

    override fun answer(proposal: Proposal): ProposalAnswer =
        if (store.file(Folder.INBOX, proposal.mid).exists()) ProposalAnswer.REJECT else ProposalAnswer.ACCEPT

    override fun receive(message: Message) {
        val f = store.file(Folder.INBOX, message.mid)
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeBytes(message.bytes())
        tmp.renameTo(f)
        store.markUnread(message.mid)
        onChange()
    }
}
