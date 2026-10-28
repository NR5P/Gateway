package com.nr5p.gateway.ui

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.nr5p.gateway.GatewayApplication

enum class AppTab { MAIL, STATIONS, CONNECT, SETTINGS }

@Composable
fun GatewayRoot(app: GatewayApplication) {
    var tab by rememberSaveable { mutableStateOf(AppTab.MAIL) }
    LaunchedEffect(Unit) { app.gateways.refreshIfDue(app.settings) }
    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == AppTab.MAIL, onClick = { tab = AppTab.MAIL }, label = { Text("Mail") },
                    icon = {
                        val n = app.store.unreadCount
                        BadgedBox(badge = { if (n > 0) Badge { Text("$n") } }) { Icon(Icons.Default.Email, null) }
                    },
                )
                NavigationBarItem(
                    selected = tab == AppTab.STATIONS, onClick = { tab = AppTab.STATIONS },
                    label = { Text("Stations") }, icon = { Icon(Icons.Default.Map, null) },
                )
                NavigationBarItem(
                    selected = tab == AppTab.CONNECT, onClick = { tab = AppTab.CONNECT },
                    label = { Text("Connect") }, icon = { Icon(Icons.Default.SettingsInputAntenna, null) },
                )
                NavigationBarItem(
                    selected = tab == AppTab.SETTINGS, onClick = { tab = AppTab.SETTINGS },
                    label = { Text("Settings") }, icon = { Icon(Icons.Default.Settings, null) },
                )
            }
        },
    ) { pad ->
        // The tab bar's inset is used up here, so a screen's imePadding adds only what the keyboard covers beyond it.
        val bottom = PaddingValues(bottom = pad.calculateBottomPadding())
        val m = Modifier.padding(bottom).consumeWindowInsets(bottom)
        when (tab) {
            AppTab.MAIL -> MailboxScreen(app, m)
            AppTab.STATIONS -> StationsScreen(app, m) { tab = AppTab.CONNECT }
            AppTab.CONNECT -> ConnectScreen(app, m)
            AppTab.SETTINGS -> SettingsScreen(app, m)
        }
    }
}
