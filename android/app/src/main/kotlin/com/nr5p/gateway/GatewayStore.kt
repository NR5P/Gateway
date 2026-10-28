package com.nr5p.gateway

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nr5p.winlink.GatewayDirectory
import com.nr5p.winlink.RMSGateway
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant

/** The RMS gateway list: the copy bundled with the app, or a newer download kept in the
 *  app's files (downloading needs a Winlink API key, see Settings). */
class GatewayStore(private val context: Context) {
    var gateways by mutableStateOf<List<RMSGateway>>(emptyList()); private set
    var updated by mutableStateOf<Instant?>(null); private set
    var refreshing by mutableStateOf(false); private set
    /** The list came from api.winlink.org (not the copy bundled with the app). */
    var downloaded by mutableStateOf(false); private set
    var loaded by mutableStateOf(false); private set
    var message by mutableStateOf("")

    private val cache get() = File(context.filesDir, "gateways.json")

    suspend fun load() {
        if (loaded) return
        val (g, fromCache) = withContext(Dispatchers.IO) {
            runCatching { GatewayDirectory.parse(cache.readText()) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { it to true }
                ?: (GatewayDirectory.parse(context.assets.open("gateways.json").use { String(it.readBytes()) }) to false)
        }
        gateways = g
        downloaded = fromCache
        updated = if (fromCache) Instant.ofEpochMilli(cache.lastModified()) else g.mapNotNull { it.lastStatus }.maxOrNull()
        loaded = true
    }

    suspend fun refresh(key: String) {
        if (key.isEmpty()) {
            message = "Add a Winlink API key in Settings to download the current list."
            return
        }
        refreshing = true
        try {
            val (data, g) = withContext(Dispatchers.IO) {
                val d = GatewayDirectory.fetch(key)
                d to GatewayDirectory.parse(d)
            }
            gateways = g
            withContext(Dispatchers.IO) { runCatching { cache.writeText(data) } }
            updated = Instant.now()
            downloaded = true
            message = ""
        } catch (e: Exception) {
            // The saved list stays in use, so this works offline.
            message = "Download failed: ${e.message}"
        } finally {
            refreshing = false
        }
    }

    /** Downloads when auto-update is on and the saved list is over a day old (or bundled). */
    suspend fun refreshIfDue(settings: Settings) {
        load()
        val key = settings.winlinkAPIKey
        if (!settings.gatewayAutoUpdate || key.isEmpty() || refreshing) return
        val u = updated
        if (downloaded && u != null && Instant.now().epochSecond - u.epochSecond < 24 * 3600) return
        refresh(key)
    }
}
