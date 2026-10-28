package com.nr5p.gateway.ui

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nr5p.gateway.Folder
import com.nr5p.gateway.GatewayApplication
import com.nr5p.gateway.LogLine
import com.nr5p.gateway.RigControlMode
import com.nr5p.gateway.TransportKind
import com.nr5p.winlink.VARALinkState
import com.nr5p.winlink.VARAMode
import com.nr5p.winlink.rig.DialFrequency
import com.nr5p.winlink.rig.RigMode
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectScreen(app: GatewayApplication, modifier: Modifier) {
    val settings = app.settings
    val session = app.session
    var showLog by remember { mutableStateOf(false) }
    if (showLog) {
        BackHandler { showLog = false }
        LogScreen(app, modifier) { showLog = false }
        return
    }
    val kind = settings.transportKind
    val listening = kind == TransportKind.LISTEN || (kind == TransportKind.TERMINAL && settings.terminalAnswer)

    Scaffold(modifier.imePadding(), topBar = { TopAppBar(title = { Text("Connect") }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            section(footer = kindHelp(kind)) {
                PickerRow(
                    "Connect to", kind,
                    listOf(
                        TransportKind.VARA to "RMS gateway (VARA)",
                        TransportKind.P2P to "Station, P2P (VARA)",
                        TransportKind.LISTEN to "Listen for P2P calls",
                        TransportKind.TERMINAL to "Terminal: BBS, node or chat",
                        TransportKind.TELNET to "Telnet (internet)",
                    ),
                    enabled = !session.running,
                ) { settings.transportKind = it }
            }
            if (kind.usesRadio) {
                section(if (kind == TransportKind.VARA) "RMS gateway" else "Station") {
                    when (kind) {
                        TransportKind.VARA -> {
                            Field("RMS call sign, e.g. W1AW-10", settings.gateway, { settings.gateway = it }, InputKind.CALLSIGN)
                            if (settings.recentGateways.isNotEmpty()) {
                                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    for (g in settings.recentGateways) {
                                        OutlinedButton({ settings.select(g) }) { Text(g, fontSize = 12.sp) }
                                    }
                                }
                            }
                        }
                        TransportKind.P2P -> Field("Their call sign", settings.peer, { settings.peer = it }, InputKind.CALLSIGN)
                        TransportKind.TERMINAL -> {
                            ToggleRow("Wait for a call", settings.terminalAnswer) { settings.terminalAnswer = it }
                            if (!settings.terminalAnswer) {
                                Field("Call sign of the BBS, node or station", settings.peer, { settings.peer = it }, InputKind.CALLSIGN)
                            }
                        }
                        else -> LabeledRow("Answering as", settings.mycall.ifEmpty { "—" })
                    }
                    PickerRow("Mode", settings.mode, listOf(VARAMode.HF to "VARA HF", VARAMode.FM to "VARA FM")) { settings.mode = it }
                    if (settings.mode == VARAMode.HF) {
                        PickerRow("Bandwidth", settings.bandwidth, listOf("500" to "500 Hz", "2300" to "2300 Hz", "2750" to "2750 Hz")) {
                            settings.bandwidth = it
                        }
                    }
                }
                if (settings.rigMode != RigControlMode.OFF) radioSection(app)
                section(
                    footer = "Run xara or VARA on another machine on your network (or on this phone, if you have a modem app " +
                        "that offers the VARA TCP interface) and point Settings at it. Keep this app open while connected.",
                ) {
                    LabeledRow("Modem", "${settings.modemHost}:${settings.modemPort}")
                    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Indicator("PTT", session.ptt, Color(0xFFE53935))
                        Spacer(Modifier.width(12.dp))
                        Indicator("BUSY", session.busy, Color(0xFFFB8C00))
                        Spacer(Modifier.weight(1f))
                        Text(stateText(session.linkState), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    session.speed?.let { SpeedRow(it) }
                }
            } else {
                section(footer = "Telnet goes over the internet straight to the Winlink CMS. No radio involved.") {
                    LabeledRow("Server", "${settings.cmsHost}:${settings.cmsPort}")
                }
            }
            if (kind == TransportKind.TERMINAL) terminalSection(app)
            section {
                if (session.running) {
                    if (session.terminalLinked) {
                        OutlinedButton(session::hangUp, Modifier.fillMaxWidth()) {
                            Icon(Icons.Default.CallEnd, null)
                            Spacer(Modifier.width(8.dp))
                            Text("Disconnect")
                        }
                    }
                    Button(
                        session::abort, Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                    ) {
                        Icon(Icons.Default.Cancel, null)
                        Spacer(Modifier.width(8.dp))
                        Text(if (listening) "Stop listening" else "Abort")
                    }
                } else {
                    Button({ session.start(app.store, app.rig) }, Modifier.fillMaxWidth(), enabled = settings.mycall.isNotEmpty()) {
                        Icon(if (listening) Icons.Default.Hearing else Icons.Default.SettingsInputAntenna, null)
                        Spacer(Modifier.width(8.dp))
                        Text(if (listening) "Listen" else "Connect")
                    }
                }
                Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (session.running) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(session.status, style = MaterialTheme.typography.bodyMedium)
                }
                session.progress?.let { p ->
                    Text("${if (p.sending) "Sending" else "Receiving"} ${p.title}", style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    LinearProgressIndicator({ p.done.toFloat() / maxOf(p.total, 1) }, Modifier.fillMaxWidth().padding(vertical = 6.dp))
                }
                LabeledRow("Outbox", "${app.store.list(Folder.OUTBOX).size} waiting")
            }
            section {
                Row(
                    Modifier.fillMaxWidth().clickable { showLog = true }.padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Session log (${session.log.size})", Modifier.weight(1f))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null)
                }
            }
        }
    }
}

/** The link's speed as the modem reports it: level, bitrate, waveform, and which way data is going. */
@Composable
private fun SpeedRow(s: com.nr5p.winlink.LinkSpeed) {
    Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (s.transmitting) Icons.Default.ArrowUpward else Icons.Default.ArrowDownward,
            if (s.transmitting) "Sending" else "Receiving",
            tint = if (s.transmitting) Color(0xFFE53935) else Color(0xFF43A047),
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text("Level ${s.level} · ${s.bps} bps", fontFamily = FontFamily.Monospace)
            s.modulation?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Text(if (s.transmitting) "sending" else "receiving", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun kindHelp(kind: TransportKind) = when (kind) {
    TransportKind.VARA -> "Sends your Outbox and downloads your mail through a gateway. Find one on the Stations tab."
    TransportKind.P2P -> "Swaps messages straight with another station, no gateway or internet: only mail addressed to their call sign goes."
    TransportKind.LISTEN -> "Waits for other stations to call you P2P and swaps messages with each caller until you stop."
    TransportKind.TERMINAL -> "Type to a packet BBS or BPQ node, or chat with another operator who is listening in Terminal mode."
    TransportKind.TELNET -> "Over the internet straight to the Winlink CMS. No radio involved."
}

private fun stateText(s: VARALinkState) = when (s) {
    VARALinkState.Closed -> "modem not open"
    VARALinkState.Idle -> "idle"
    is VARALinkState.Connecting -> "calling ${s.target}"
    is VARALinkState.Connected -> "linked ${s.answerer} ${s.width}"
    VARALinkState.Disconnecting -> "disconnecting"
}

/** Dial frequency, what the radio is doing, and the tuner. */
private fun androidx.compose.foundation.lazy.LazyListScope.radioSection(app: GatewayApplication) {
    val settings = app.settings
    val rig = app.rig
    val name = rig.connected
    section(
        "Radio",
        name?.let {
            "$it. Gateway sets the frequency${if (settings.rigSetDataMode) " and data mode" else ""} before calling" +
                "${if (settings.rigKeysPTT) " and keys the radio when the modem transmits" else ""}."
        } ?: "Finds RigHelm on your network, or a rigctld. Leave the frequency empty to call on whatever the radio is tuned to.",
    ) {
        val scope = rememberCoroutineScope()
        Field("Dial frequency, kHz (e.g. 14105.0)", settings.dialFrequency, { settings.dialFrequency = it }, InputKind.NUMBER)
        if (name != null) {
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(rig.status.frequency?.let(DialFrequency::format) ?: "—", fontFamily = FontFamily.Monospace)
                Spacer(Modifier.width(12.dp))
                Text(rig.status.mode ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Indicator("TX", rig.status.transmitting, Color(0xFFE53935))
            }
            Row(Modifier.fillMaxWidth()) {
                FilledTonalButton(
                    {
                        val hz = DialFrequency.parse(settings.dialFrequency) ?: return@FilledTonalButton
                        scope.launch {
                            runCatching { rig.prepare(hz, if (settings.mode == VARAMode.FM) RigMode.DATA_FM else RigMode.DATA_USB) }
                                .onFailure { rig.message = it.message ?: "" }
                        }
                    },
                    enabled = DialFrequency.parse(settings.dialFrequency) != null && !app.session.running,
                ) { Text("Set frequency") }
                Spacer(Modifier.weight(1f))
                FilledTonalButton({ scope.launch { rig.tune() } }, enabled = !app.session.running) {
                    Icon(Icons.Default.Tune, null)
                    Spacer(Modifier.width(6.dp))
                    Text("Tune")
                }
            }
        } else {
            TextButton(
                { scope.launch { runCatching { rig.open() }.onFailure { if (rig.message.isEmpty()) rig.message = it.message ?: "" } } },
                enabled = !rig.scanning,
            ) {
                Icon(Icons.Default.Search, null)
                Spacer(Modifier.width(8.dp))
                Text(if (rig.scanning) "Looking for the radio…" else "Find radio")
                if (rig.scanning) {
                    Spacer(Modifier.width(8.dp))
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                }
            }
        }
        if (rig.message.isNotEmpty()) {
            Text(rig.message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 6.dp))
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.terminalSection(app: GatewayApplication) {
    val session = app.session
    section("Terminal") {
        var line by remember { mutableStateOf("") }
        val scroll = rememberScrollState()
        LaunchedEffect(session.terminal) { scroll.animateScrollTo(scroll.maxValue) }
        Box(Modifier.fillMaxWidth().heightIn(min = 180.dp, max = 320.dp).verticalScroll(scroll).padding(vertical = 6.dp)) {
            SelectionContainer {
                Text(session.terminal.ifEmpty { "Nothing yet." }, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
        }
        fun send() {
            if (!session.terminalLinked) return
            session.sendTerminal(line)
            line = ""
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                line, { line = it }, Modifier.weight(1f),
                placeholder = { Text(if (session.terminalLinked) "Type and press Return" else "Not connected") },
                enabled = session.terminalLinked, singleLine = true,
                keyboardOptions = InputKind.PLAIN.options(ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { send() }),
            )
            IconButton(::send, enabled = session.terminalLinked) { Icon(Icons.AutoMirrored.Filled.Send, "Send") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LogScreen(app: GatewayApplication, modifier: Modifier, onBack: () -> Unit) {
    val session = app.session
    val context = LocalContext.current
    val list = rememberLazyListState()
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(session.log.size) { if (session.log.isNotEmpty()) list.scrollToItem(session.log.size - 1) }
    Scaffold(
        modifier,
        topBar = {
            TopAppBar(
                title = { Text("Session Log") },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    Box {
                        IconButton({ menu = true }) { Icon(Icons.Default.MoreVert, "More") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem(
                                text = { Text((if (app.settings.showModemTraffic) "✓ " else "") + "Show modem commands") },
                                onClick = { app.settings.showModemTraffic = !app.settings.showModemTraffic },
                            )
                            DropdownMenuItem(text = { Text("Share") }, onClick = {
                                menu = false
                                val text = session.log.joinToString("\n") { "${it.time} ${prefix(it.kind)} ${it.text}" }
                                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                                context.startActivity(Intent.createChooser(send, "Session log"))
                            })
                            DropdownMenuItem(text = { Text("Clear", color = MaterialTheme.colorScheme.error) }, onClick = {
                                menu = false
                                session.clearLog()
                            })
                        }
                    }
                },
            )
        },
    ) { pad ->
        SelectionContainer(Modifier.padding(pad)) {
            LazyColumn(state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 6.dp)) {
                items(session.log, key = { it.id }) { l ->
                    val c = color(l.kind)
                    Row(Modifier.padding(vertical = 1.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(l.time.time(), fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(prefix(l.kind), fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = c)
                        Text(l.text, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = c)
                    }
                }
            }
        }
    }
}

private fun prefix(k: LogLine.Kind) = when (k) {
    LogLine.Kind.SENT -> ">"
    LogLine.Kind.RECEIVED -> "<"
    LogLine.Kind.MODEM_SENT -> "»"
    LogLine.Kind.MODEM_RECEIVED -> "«"
    LogLine.Kind.INFO -> "·"
    LogLine.Kind.ERROR -> "!"
}

@Composable
private fun color(k: LogLine.Kind) = when (k) {
    LogLine.Kind.SENT -> Color(0xFF1E88E5)
    LogLine.Kind.RECEIVED -> MaterialTheme.colorScheme.onSurface
    LogLine.Kind.MODEM_SENT, LogLine.Kind.MODEM_RECEIVED -> MaterialTheme.colorScheme.onSurfaceVariant
    LogLine.Kind.INFO -> Color(0xFF43A047)
    LogLine.Kind.ERROR -> MaterialTheme.colorScheme.error
}
