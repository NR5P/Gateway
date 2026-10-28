package com.nr5p.gateway.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import com.nr5p.gateway.Folder
import com.nr5p.gateway.GatewayApplication
import com.nr5p.winlink.Maidenhead
import com.nr5p.winlink.PositionReport
import java.util.Locale
import kotlin.math.abs

/** Puts a position report in the Outbox: a message to QTH that shows this station on the
 *  Winlink map once it is sent. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PositionReportDialog(app: GatewayApplication, dismiss: () -> Unit) {
    val context = LocalContext.current
    val home = remember { Maidenhead.coordinate(app.settings.locator.trim()) }
    var lat by remember { mutableStateOf(home?.let { String.format(Locale.US, "%.4f", it.lat) } ?: "") }
    var lon by remember { mutableStateOf(home?.let { String.format(Locale.US, "%.4f", it.lon) } ?: "") }
    var comment by remember { mutableStateOf("") }
    var error by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var locMessage by remember { mutableStateOf("") }

    fun locate() {
        busy = true
        locMessage = ""
        oneShotLocation(context) { la, lo, msg ->
            busy = false
            if (la != null && lo != null) {
                lat = String.format(Locale.US, "%.5f", la)
                lon = String.format(Locale.US, "%.5f", lo)
            } else {
                locMessage = msg
            }
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) locate() else locMessage = "Location access is off for Gateway."
    }

    fun post() {
        val mycall = app.settings.mycall
        if (mycall.isEmpty()) {
            error = "Set your call sign in Settings first."
            return
        }
        val la = lat.trim().toDoubleOrNull()
        val lo = lon.trim().toDoubleOrNull()
        if (la == null || lo == null || abs(la) > 90 || abs(lo) > 180) {
            error = "Enter a latitude (-90 to 90) and longitude (-180 to 180)."
            return
        }
        try {
            app.store.save(PositionReport(latitude = la, longitude = lo, comment = comment).message(mycall), Folder.OUTBOX)
            dismiss()
        } catch (e: Exception) {
            error = e.message ?: "Could not save"
        }
    }

    Dialog(dismiss, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Scaffold(
            modifier = Modifier.imePadding(),
            topBar = {
                TopAppBar(
                    title = { Text("Position Report") },
                    navigationIcon = { IconButton(dismiss) { Icon(Icons.Default.Close, "Cancel") } },
                    actions = { TextButton(::post) { Text("Post", fontWeight = FontWeight.Bold) } },
                )
            },
        ) { pad ->
            LazyColumn(Modifier.padding(pad)) {
                section(
                    "Position",
                    "Decimal degrees: south and west are negative. Filled in from your grid locator, which is only accurate to tens of km.",
                ) {
                    Field("Latitude (e.g. 30.2672)", lat, { lat = it })
                    Field("Longitude (e.g. -97.7431)", lon, { lon = it })
                    TextButton(enabled = !busy, onClick = {
                        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
                        if (fine || coarse) {
                            locate()
                        } else {
                            permission.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                        }
                    }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.MyLocation, null)
                            Spacer(Modifier.width(8.dp))
                            Text("Use this device's location")
                            if (busy) {
                                Spacer(Modifier.width(8.dp))
                                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                            }
                        }
                    }
                    if (locMessage.isNotEmpty()) Text(locMessage, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                section("Comment (up to 80 characters)") {
                    Field("e.g. QRV 145.500", comment, { comment = it.take(80) })
                }
                if (error.isNotEmpty()) {
                    section { Text(error, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 8.dp)) }
                }
            }
        }
    }
}

@SuppressLint("MissingPermission")
private fun oneShotLocation(context: Context, done: (Double?, Double?, String) -> Unit) {
    val lm = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    val provider = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        .firstOrNull { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
    if (provider == null) {
        done(null, null, "No location: location is turned off on this device.")
        return
    }
    try {
        val cancel: android.os.CancellationSignal? = null
        LocationManagerCompat.getCurrentLocation(lm, provider, cancel, ContextCompat.getMainExecutor(context)) { loc: android.location.Location? ->
            val l = loc ?: runCatching { lm.getLastKnownLocation(provider) }.getOrNull()
            if (l != null) done(l.latitude, l.longitude, "") else done(null, null, "No location: no fix yet. Try again outdoors.")
        }
    } catch (e: Exception) {
        done(null, null, "No location: ${e.message}")
    }
}
