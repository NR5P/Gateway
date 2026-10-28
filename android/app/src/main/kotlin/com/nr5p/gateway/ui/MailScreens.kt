package com.nr5p.gateway.ui

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Forward
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.automirrored.filled.ReplyAll
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Drafts
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Outbox
import androidx.compose.material.icons.filled.PinDrop
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.nr5p.gateway.Folder
import com.nr5p.gateway.GatewayApplication
import com.nr5p.gateway.StoredMessage
import com.nr5p.winlink.Attachment
import com.nr5p.winlink.Message
import java.io.File

private sealed class MailRoute {
    data class InFolder(val folder: Folder) : MailRoute()
    data class Read(val id: String) : MailRoute()
}

fun Folder.icon() = when (this) {
    Folder.INBOX -> Icons.Default.Inbox
    Folder.OUTBOX -> Icons.Default.Outbox
    Folder.SENT -> Icons.AutoMirrored.Filled.Send
    Folder.DRAFTS -> Icons.Default.Drafts
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MailboxScreen(app: GatewayApplication, modifier: Modifier) {
    val store = app.store
    val stack = remember { mutableStateListOf<MailRoute>() }
    var composing by remember { mutableStateOf<ComposeDraft?>(null) }
    var reportingPosition by remember { mutableStateOf(false) }

    BackHandler(stack.isNotEmpty()) { stack.removeAt(stack.size - 1) }

    Box(modifier) {
        when (val top = stack.lastOrNull()) {
            null -> Scaffold(
                topBar = {
                    TopAppBar(
                        title = { Text("Mailboxes") },
                        actions = {
                            IconButton({ reportingPosition = true }) { Icon(Icons.Default.PinDrop, "Position report") }
                            IconButton({ composing = ComposeDraft() }) { Icon(Icons.Default.EditNote, "New message") }
                        },
                    )
                },
            ) { pad ->
                LazyColumn(Modifier.padding(pad)) {
                    items(Folder.entries) { f ->
                        val n = if (f == Folder.INBOX) store.unreadCount else store.list(f).size
                        ListItem(
                            headlineContent = { Text(f.title) },
                            leadingContent = { Icon(f.icon(), null, tint = MaterialTheme.colorScheme.primary) },
                            trailingContent = {
                                if (n > 0) {
                                    Text("$n", color = if (f == Folder.INBOX) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            },
                            modifier = Modifier.clickable { stack.add(MailRoute.InFolder(f)) },
                        )
                        HorizontalDivider(Modifier.padding(start = 56.dp))
                    }
                }
            }
            is MailRoute.InFolder -> FolderScreen(app, top.folder, onBack = { stack.removeAt(stack.size - 1) }) {
                stack.add(MailRoute.Read(it.id))
            }
            is MailRoute.Read -> {
                val s = Folder.entries.flatMap { store.list(it) }.firstOrNull { it.id == top.id }
                if (s == null) {
                    LaunchedEffect(Unit) { stack.removeAt(stack.size - 1) }
                } else {
                    MessageScreen(app, s, onBack = { stack.removeAt(stack.size - 1) }) { composing = it }
                }
            }
        }
    }

    composing?.let { d -> ComposeDialog(app, d) { composing = null } }
    if (reportingPosition) PositionReportDialog(app) { reportingPosition = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FolderScreen(app: GatewayApplication, folder: Folder, onBack: () -> Unit, open: (StoredMessage) -> Unit) {
    val store = app.store
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(folder.title) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
    ) { pad ->
        val list = store.list(folder)
        if (list.isEmpty()) {
            Column(Modifier.padding(pad).fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(folder.icon(), null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("No messages", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
                if (folder == Folder.OUTBOX) {
                    Text("Messages you write wait here until the next connection.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(Modifier.padding(pad)) {
                items(list, key = { it.id }) { s ->
                    val state = rememberSwipeToDismissBoxState(confirmValueChange = {
                        if (it == SwipeToDismissBoxValue.EndToStart) store.delete(s)
                        it == SwipeToDismissBoxValue.EndToStart
                    })
                    SwipeToDismissBox(
                        state, enableDismissFromStartToEnd = false,
                        backgroundContent = {
                            Box(Modifier.fillMaxSize().background(Color(0xFFD32F2F)).padding(end = 20.dp), contentAlignment = Alignment.CenterEnd) {
                                Icon(Icons.Default.Delete, "Delete", tint = Color.White)
                            }
                        },
                    ) {
                        MessageRow(s, Modifier.background(MaterialTheme.colorScheme.surface).clickable { open(s) })
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun MessageRow(stored: StoredMessage, modifier: Modifier) {
    val m = stored.message
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (stored.unread) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary))
                Spacer(Modifier.width(6.dp))
            }
            Text(
                if (stored.folder == Folder.INBOX) m.from.addr else m.receivers.joinToString(", ") { it.addr },
                style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            m.date?.let { Text(it.short(), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (m.files.isNotEmpty()) Icon(Icons.Default.AttachFile, null, Modifier.size(14.dp))
            Text(m.subject, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            m.bodyText.replace("\r\n", " "), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageScreen(app: GatewayApplication, stored: StoredMessage, onBack: () -> Unit, compose: (ComposeDraft) -> Unit) {
    val m = stored.message
    LaunchedEffect(stored.id) { app.store.markRead(stored) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stored.folder.title) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
        },
        bottomBar = {
            BottomAppBar {
                IconButton({ compose(ComposeDraft.reply(m, false)) }) { Icon(Icons.AutoMirrored.Filled.Reply, "Reply") }
                IconButton({ compose(ComposeDraft.reply(m, true)) }) { Icon(Icons.AutoMirrored.Filled.ReplyAll, "Reply all") }
                IconButton({ compose(ComposeDraft.forward(m)) }) { Icon(Icons.AutoMirrored.Filled.Forward, "Forward") }
                Spacer(Modifier.weight(1f))
                if (stored.folder == Folder.OUTBOX || stored.folder == Folder.DRAFTS) {
                    IconButton({ compose(ComposeDraft.edit(stored)) }) { Icon(Icons.Default.Edit, "Edit") }
                }
                IconButton({
                    app.store.delete(stored)
                    onBack()
                }) { Icon(Icons.Default.Delete, "Delete") }
            }
        },
    ) { pad ->
        Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp)) {
            Text(m.subject, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Spacer(Modifier.size(8.dp))
            HeaderLine("From", m.from.addr)
            if (m.to.isNotEmpty()) HeaderLine("To", m.to.joinToString(", ") { it.addr })
            if (m.cc.isNotEmpty()) HeaderLine("Cc", m.cc.joinToString(", ") { it.addr })
            m.date?.let { HeaderLine("Date", it.dateTime()) }
            HeaderLine("MID", m.mid)
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            SelectionContainer {
                Text(m.bodyText.replace("\r\n", "\n"), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium)
            }
            if (m.files.isNotEmpty()) {
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                for (f in m.files) AttachmentRow(f)
            }
        }
    }
}

@Composable
private fun HeaderLine(label: String, value: String) {
    Row(Modifier.padding(vertical = 1.dp)) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(48.dp))
        SelectionContainer { Text(value, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun AttachmentRow(file: Attachment) {
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Description, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(file.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f, fill = false))
        Spacer(Modifier.width(6.dp))
        Text(byteCount(file.data.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        IconButton({
            val dir = File(context.cacheDir, "attachments").apply { mkdirs() }
            val f = File(dir, file.name.replace("/", "_"))
            f.writeBytes(file.data)
            val uri = FileProvider.getUriForFile(context, context.packageName + ".files", f)
            val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "application/octet-stream"
            val send = Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startActivity(Intent.createChooser(send, file.name))
        }) { Icon(Icons.Default.Share, "Share ${file.name}") }
    }
}

// Compose

data class ComposeDraft(
    val to: String = "",
    val cc: String = "",
    val subject: String = "",
    val body: String = "",
    val files: List<Attachment> = emptyList(),
    val replacing: StoredMessage? = null,
) {
    companion object {
        fun reply(m: Message, all: Boolean) = ComposeDraft(
            to = m.from.addr,
            cc = if (all) (m.to + m.cc).joinToString(", ") { it.addr } else "",
            subject = if (m.subject.lowercase().startsWith("re:")) m.subject else "Re: " + m.subject,
            body = "\n\n" + quote(m),
        )

        fun forward(m: Message) = ComposeDraft(
            subject = if (m.subject.lowercase().startsWith("fw:")) m.subject else "Fw: " + m.subject,
            body = "\n\n---------- Forwarded message ----------\nFrom: ${m.from.addr}\nSubject: ${m.subject}\n\n" +
                m.bodyText.replace("\r\n", "\n"),
            files = m.files,
        )

        fun edit(s: StoredMessage): ComposeDraft {
            val m = s.message
            return ComposeDraft(
                to = m.to.joinToString(", ") { it.addr }, cc = m.cc.joinToString(", ") { it.addr }, subject = m.subject,
                body = m.bodyText.replace("\r\n", "\n"), files = m.files, replacing = s,
            )
        }

        private fun quote(m: Message): String {
            val lines = m.bodyText.replace("\r\n", "\n").split("\n")
            return "On ${m.date?.dateTime() ?: ""}, ${m.from.addr} wrote:\n" + lines.joinToString("\n") { "> $it" }
        }
    }
}

/** Attachments travel at a few hundred bytes per second on HF; warn well before they hurt. */
private const val SIZE_WARNING = 30_000

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ComposeDialog(app: GatewayApplication, start: ComposeDraft, dismiss: () -> Unit) {
    val context = LocalContext.current
    var d by remember { mutableStateOf(start) }
    var error by remember { mutableStateOf<String?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        val added = uris.mapNotNull { u ->
            val name = context.contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            } ?: u.lastPathSegment ?: "file"
            val data = context.contentResolver.openInputStream(u)?.use { it.readBytes() } ?: return@mapNotNull null
            Attachment(name, data)
        }
        d = d.copy(files = d.files + added)
    }

    fun split(s: String) = s.split(',', ';', ' ').map { it.trim() }.filter { it.isNotEmpty() }

    /** Queues the message in the Outbox (or Drafts); it goes out on the next connection. */
    fun post(folder: Folder) {
        val mycall = app.settings.mycall
        if (mycall.isEmpty()) {
            error = "Set your call sign in Settings first."
            return
        }
        val m = Message(mycall)
        m.addTo(split(d.to))
        m.addCc(split(d.cc))
        m.subject = d.subject.trim()
        m.setBody(d.body.ifEmpty { " " })
        for (f in d.files) m.addFile(f)
        try {
            if (folder == Folder.OUTBOX) m.validate()
            d.replacing?.let { app.store.delete(it) }
            app.store.save(m, folder)
            dismiss()
        } catch (e: Exception) {
            error = e.message
        }
    }

    val total = d.body.toByteArray().size + d.files.sumOf { it.data.size }
    Dialog(dismiss, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Scaffold(
            modifier = Modifier.imePadding(),
            topBar = {
                TopAppBar(
                    title = { Text(if (d.replacing == null) "New Message" else "Edit Message") },
                    navigationIcon = { IconButton(dismiss) { Icon(Icons.Default.Close, "Cancel") } },
                    actions = {
                        TextButton({ post(Folder.DRAFTS) }) { Text("Save draft") }
                        TextButton({ post(Folder.OUTBOX) }) { Text("Post", fontWeight = FontWeight.Bold) }
                    },
                )
            },
        ) { pad ->
            Column(Modifier.padding(pad).verticalScroll(rememberScrollState()).padding(16.dp)) {
                Field("To (call sign or email)", d.to, { d = d.copy(to = it) }, InputKind.EMAIL)
                Field("Cc", d.cc, { d = d.copy(cc = it) }, InputKind.EMAIL)
                Field("Subject", d.subject, { d = d.copy(subject = it) })
                Field("Message", d.body, { d = d.copy(body = it) }, singleLine = false, minLines = 10, monospace = true)
                for ((i, f) in d.files.withIndex()) {
                    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.AttachFile, null, Modifier.size(18.dp))
                        Text(f.name, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        Text(byteCount(f.data.size), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                        IconButton({ d = d.copy(files = d.files.filterIndexed { j, _ -> j != i }) }) { Icon(Icons.Default.Close, "Remove ${f.name}") }
                    }
                }
                TextButton({ pick.launch(arrayOf("*/*")) }) {
                    Icon(Icons.Default.Upload, null)
                    Spacer(Modifier.width(6.dp))
                    Text("Attach file")
                }
                if (total > SIZE_WARNING) {
                    Text("This message is ${byteCount(total)}. Over HF that can take many minutes.", color = Color(0xFFE65100), style = MaterialTheme.typography.bodySmall)
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }
            }
        }
    }
}
