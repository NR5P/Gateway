package com.nr5p.gateway.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.unit.dp
import com.nr5p.gateway.BuildConfig
import com.nr5p.gateway.GatewayApplication
import com.nr5p.gateway.RigControlMode
import com.nr5p.winlink.rig.RigEndpoint
import com.nr5p.winlink.rig.RigHelmRig
import com.nr5p.winlink.rig.RigctldRig
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(app: GatewayApplication, modifier: Modifier) {
    val settings = app.settings
    val rig = app.rig
    val gateways = app.gateways
    val scope = rememberCoroutineScope()
    var password by remember(settings.mycall) { mutableStateOf(settings.password) }
    var rigPassword by remember { mutableStateOf(settings.rigPassword) }
    var apiKey by remember { mutableStateOf(settings.winlinkAPIKey) }

    LaunchedEffect(Unit) {
        if (settings.rigMode == RigControlMode.AUTO && rig.endpoints.isEmpty()) rig.scan()
    }

    Scaffold(modifier.imePadding(), topBar = { TopAppBar(title = { Text("Settings") }) }) { pad ->
        LazyColumn(Modifier.padding(pad)) {
            section("Station") {
                Field("Call sign", settings.callsign, { settings.callsign = it }, InputKind.CALLSIGN)
                Field("Grid locator (e.g. EM10)", settings.locator, { settings.locator = it }, InputKind.CALLSIGN)
            }
            section(
                "Winlink account",
                "Stored encrypted on this device only (Android Keystore). Used to answer the gateway's secure login " +
                    "challenge; the password itself is never sent.",
            ) {
                Field("Winlink password", password, { password = it }, password = true)
                TextButton({ settings.password = password }, enabled = password != settings.password) { Text("Save password") }
            }
            section(
                "Radio control",
                "Android gives apps no direct serial access to most radios, so the radio is reached over the network: " +
                    "RigHelm on the computer it is plugged into (found automatically), or rigctld. Transmitting through " +
                    "RigHelm needs its password and remote transmit allowed. Turn off keying if the modem keys the radio itself.",
            ) {
                PickerRow("Radio control", settings.rigMode, RigControlMode.entries.map { it to it.label }) {
                    settings.rigMode = it
                    if (it == RigControlMode.RIGHELM) settings.rigPort = RigHelmRig.DEFAULT_PORT
                    if (it == RigControlMode.RIGCTLD) settings.rigPort = RigctldRig.DEFAULT_PORT
                    rig.disconnect()
                }
                if (settings.rigMode == RigControlMode.RIGHELM || settings.rigMode == RigControlMode.RIGCTLD) {
                    Field("Host", settings.rigHost, { settings.rigHost = it }, InputKind.URL)
                    Field("Port", settings.rigPort.toString(), { v -> v.toIntOrNull()?.let { settings.rigPort = it } }, InputKind.NUMBER)
                }
                if (settings.rigMode == RigControlMode.AUTO) {
                    for (e in rig.endpoints) {
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                settings.rigLastEndpoint = e.id
                                rig.disconnect()
                            }.padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(e.title)
                                Text(
                                    if (e.kind == RigEndpoint.Kind.RIGHELM) {
                                        "${e.host}:${e.port} · radio ${e.radio}" + if (e.auth) "" else " · receive only (no password)"
                                    } else if (e.host == "127.0.0.1") "hamlib, on this device" else "hamlib",
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            if (e.id == settings.rigLastEndpoint) Icon(Icons.Default.Check, "Selected", tint = MaterialTheme.colorScheme.primary)
                        }
                    }
                    TextButton({ scope.launch { rig.scan() } }, enabled = !rig.scanning) {
                        Text(if (rig.scanning) "Searching…" else "Search for radios")
                    }
                }
                if (settings.rigMode != RigControlMode.OFF) {
                    if (settings.rigMode != RigControlMode.RIGCTLD) {
                        Field("RigHelm password", rigPassword, { rigPassword = it }, password = true)
                        TextButton({
                            settings.rigPassword = rigPassword
                            rig.disconnect()
                        }, enabled = rigPassword != settings.rigPassword) { Text("Save RigHelm password") }
                    }
                    ToggleRow("Key the radio when the modem transmits", settings.rigKeysPTT) { settings.rigKeysPTT = it }
                    ToggleRow("Set data mode (DATA-U / DATA-FM)", settings.rigSetDataMode) { settings.rigSetDataMode = it }
                }
            }
            section(
                "VARA modem",
                "The VARA TCP interface: xara or VARA on a computer on your network (its LAN address), or 127.0.0.1 for " +
                    "a modem app on this phone.",
            ) {
                Field("Host", settings.modemHost, { settings.modemHost = it }, InputKind.URL)
                Field("Command port", settings.modemPort.toString(), { v -> v.toIntOrNull()?.let { settings.modemPort = it } }, InputKind.NUMBER)
                LabeledRow("Data port", "${settings.modemPort + 1}")
            }
            val updated = gateways.updated
            section(
                "Gateway list",
                (
                    if (gateways.downloaded) {
                        "${gateways.gateways.size} VARA gateways, downloaded ${updated?.dateTime() ?: ""}"
                    } else {
                        "${gateways.gateways.size} VARA gateways from the list built into the app (${updated?.dateOnly() ?: ""})"
                    }
                    ) + ". The last list downloaded is kept on this device, so Stations works with no internet. Downloading " +
                    "from api.winlink.org needs an API key, which the Winlink Development Team issues for each program: ask " +
                    "them for one and enter it here.",
            ) {
                Field("Winlink API key", apiKey, { apiKey = it }, password = true)
                ToggleRow("Update automatically (daily)", settings.gatewayAutoUpdate) { settings.gatewayAutoUpdate = it }
                TextButton({
                    settings.winlinkAPIKey = apiKey
                    scope.launch { gateways.refresh(apiKey) }
                }, enabled = apiKey.isNotEmpty() && !gateways.refreshing) {
                    Text("Update now")
                    if (gateways.refreshing) {
                        Spacer(Modifier.width(8.dp))
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    }
                }
                if (gateways.message.isNotEmpty()) {
                    Text(gateways.message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }
            section("Winlink CMS (telnet)") {
                Field("Host", settings.cmsHost, { settings.cmsHost = it }, InputKind.URL)
                Field("Port", settings.cmsPort.toString(), { v -> v.toIntOrNull()?.let { settings.cmsPort = it } }, InputKind.NUMBER)
            }
            section {
                Text(
                    "Gateway ${BuildConfig.VERSION_NAME}. B2F protocol code ported from wl2k-go by Martin Hebnes Pedersen (LA5NTA), MIT licence. " +
                        "Map data © OpenStreetMap contributors.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
        }
    }
}
