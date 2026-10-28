package com.nr5p.gateway.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.nr5p.gateway.BuildConfig
import com.nr5p.gateway.GatewayApplication
import com.nr5p.gateway.RigControlMode
import com.nr5p.gateway.TransportKind
import com.nr5p.winlink.LatLon
import com.nr5p.winlink.Maidenhead
import com.nr5p.winlink.RMSChannel
import com.nr5p.winlink.RMSGateway
import com.nr5p.winlink.VARAMode
import com.nr5p.winlink.rig.DialFrequency
import com.nr5p.winlink.rig.RigMode
import kotlinx.coroutines.launch
import org.osmdroid.config.Configuration
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import kotlin.math.abs

enum class StationFilter(val label: String) { HF("VARA HF"), FM("VARA FM"), ALL("All") }

private const val ANY_BAND = "Any band"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StationsScreen(app: GatewayApplication, modifier: Modifier, showConnect: () -> Unit) {
    val settings = app.settings
    val gateways = app.gateways
    val scope = rememberCoroutineScope()
    var showList by rememberSaveable { mutableStateOf(false) }
    var filter by rememberSaveable { mutableStateOf(StationFilter.HF) }
    var band by rememberSaveable { mutableStateOf(ANY_BAND) }
    var search by rememberSaveable { mutableStateOf("") }
    var selected by remember { mutableStateOf<RMSGateway?>(null) }
    var bounds by remember { mutableStateOf<BoundingBox?>(null) }
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { gateways.refreshIfDue(settings) }

    val home = Maidenhead.coordinate(settings.locator.trim())

    fun channels(g: RMSGateway) = g.channels.filter { c ->
        (filter == StationFilter.ALL || (filter == StationFilter.FM) == c.isFM) && (band == ANY_BAND || c.band == band)
    }

    val q = search.trim().uppercase()
    val matching = gateways.gateways.filter { channels(it).isNotEmpty() && (q.isEmpty() || it.callsign.contains(q)) }
    fun distance(g: RMSGateway, h: LatLon) = Maidenhead.distance(h, LatLon(g.latitude, g.longitude))
    val sorted = if (home == null) matching.sortedBy { it.callsign } else matching.sortedBy { distance(it, home) }

    /** Markers in view, at most a few hundred (nearest the middle of the map first). */
    val onMap = bounds?.let { b ->
        val c = LatLon(b.centerLatitude, b.centerLongitude)
        val inView = matching.filter {
            it.latitude in b.latSouth..b.latNorth &&
                (if (b.lonWest <= b.lonEast) it.longitude in b.lonWest..b.lonEast else it.longitude >= b.lonWest || it.longitude <= b.lonEast)
        }
        if (inView.size <= 300) inView else inView.sortedBy { Maidenhead.distance(c, LatLon(it.latitude, it.longitude)) }.take(300)
    } ?: sorted.take(300)

    val bands = listOf(ANY_BAND) + gateways.gateways
        .flatMap { g -> g.channels.filter { filter == StationFilter.ALL || (filter == StationFilter.FM) == it.isFM }.map { it.band } }
        .toSet().sortedByDescending { it.dropLast(1).toDoubleOrNull() ?: 0.0 }

    Scaffold(
        modifier,
        topBar = {
            TopAppBar(
                title = { Text("Stations") },
                actions = {
                    IconButton({ showList = !showList }) {
                        Icon(if (showList) Icons.Default.Map else Icons.AutoMirrored.Filled.List, if (showList) "Map" else "List")
                    }
                    Box {
                        IconButton({ menu = true }) { Icon(Icons.Default.FilterList, "Filter") }
                        DropdownMenu(menu, { menu = false }) {
                            for (f in StationFilter.entries) {
                                DropdownMenuItem(text = { Text((if (f == filter) "✓ " else "    ") + f.label) }, onClick = {
                                    filter = f
                                    band = ANY_BAND
                                    menu = false
                                })
                            }
                            HorizontalDivider()
                            for (b in bands) {
                                DropdownMenuItem(text = { Text((if (b == band) "✓ " else "    ") + b) }, onClick = {
                                    band = b
                                    menu = false
                                })
                            }
                            HorizontalDivider()
                            DropdownMenuItem(text = { Text("Update now") }, onClick = {
                                menu = false
                                scope.launch { gateways.refresh(settings.winlinkAPIKey) }
                            })
                        }
                    }
                },
            )
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            if (!gateways.loaded) {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            } else if (showList) {
                Column {
                    OutlinedTextField(
                        search, { search = it }, Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                        placeholder = { Text("Call sign") }, singleLine = true, keyboardOptions = InputKind.CALLSIGN.options(),
                    )
                    LazyColumn(Modifier.weight(1f)) {
                        items(sorted, key = { it.id }) { g ->
                            Row(
                                Modifier.fillMaxWidth().clickable { selected = g }.padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(g.callsign, style = MaterialTheme.typography.titleSmall)
                                    Text(
                                        channels(g).map { "${it.band} ${DialFrequency.format(it.dial.toLong())}" }.distinct().joinToString(" · "),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2,
                                    )
                                }
                                if (home != null) {
                                    Column(horizontalAlignment = Alignment.End) {
                                        Text("${distance(g, home).toInt()} km", fontFamily = FontFamily.Monospace)
                                        Text(
                                            "${Maidenhead.bearing(home, LatLon(g.latitude, g.longitude)).toInt()}°",
                                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                            HorizontalDivider()
                        }
                    }
                }
            } else {
                GatewayMap(home, onMap, filter, onBounds = { bounds = it }) { selected = it }
            }
            Footer(app, matching.size, filter, band, home != null, Modifier.align(Alignment.BottomCenter).padding(8.dp))
        }
    }

    selected?.let { g ->
        StationDetailSheet(app, g, channels(g), home, dismiss = { selected = null }) {
            selected = null
            showConnect()
        }
    }
}

@Composable
private fun Footer(app: GatewayApplication, count: Int, filter: StationFilter, band: String, haveHome: Boolean, modifier: Modifier) {
    val g = app.gateways
    Column(
        modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val s = MaterialTheme.typography.bodySmall
        Text("$count gateways · ${filter.label}${if (band == ANY_BAND) "" else " · $band"}", style = s)
        g.updated?.let { Text("${if (g.downloaded) "Updated" else "Built-in list from"} ${if (g.downloaded) it.dateTime() else it.dateOnly()}", style = s) }
        if (g.message.isNotEmpty()) Text(g.message, style = s, color = MaterialTheme.colorScheme.error)
        if (g.refreshing) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        if (!haveHome) Text("Set your grid locator in Settings to sort by distance.", style = s)
    }
}

private fun markerIcon(context: Context, color: Int, home: Boolean): BitmapDrawable {
    val d = context.resources.displayMetrics.density
    val size = (if (home) 22 else 18) * d
    val bmp = Bitmap.createBitmap(size.toInt(), size.toInt(), Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    p.color = android.graphics.Color.WHITE
    c.drawCircle(size / 2, size / 2, size / 2, p)
    p.color = color
    c.drawCircle(size / 2, size / 2, size / 2 - 2 * d, p)
    if (!home) {
        // A small mast.
        p.color = android.graphics.Color.WHITE
        p.strokeWidth = 1.6f * d
        p.style = Paint.Style.STROKE
        c.drawLine(size / 2, size * 0.28f, size * 0.33f, size * 0.74f, p)
        c.drawLine(size / 2, size * 0.28f, size * 0.67f, size * 0.74f, p)
        c.drawLine(size * 0.4f, size * 0.55f, size * 0.6f, size * 0.55f, p)
    }
    return BitmapDrawable(context.resources, bmp)
}

@Composable
private fun GatewayMap(
    home: LatLon?,
    gateways: List<RMSGateway>,
    filter: StationFilter,
    onBounds: (BoundingBox) -> Unit,
    onSelect: (RMSGateway) -> Unit,
) {
    val context = LocalContext.current
    val teal = Teal.toArgb()
    val purple = 0xFF8E24AA.toInt()
    val icons = remember { Triple(markerIcon(context, teal, false), markerIcon(context, purple, false), markerIcon(context, 0xFF1E88E5.toInt(), true)) }
    val map = remember {
        Configuration.getInstance().userAgentValue = "Gateway/${BuildConfig.VERSION_NAME} (${context.packageName})"
        Configuration.getInstance().osmdroidBasePath = context.cacheDir.resolve("osmdroid")
        Configuration.getInstance().osmdroidTileCache = context.cacheDir.resolve("osmdroid/tiles")
        MapView(context).apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(true)
            zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
            isTilesScaledToDpi = true
            minZoomLevel = 2.0
            controller.setZoom(if (home != null) 5.0 else 3.0)
            controller.setCenter(GeoPoint(home?.lat ?: 30.0, home?.lon ?: -40.0))
        }
    }
    DisposableEffect(map) {
        map.onResume()
        var lastSent: BoundingBox? = null
        val listener = object : MapListener {
            fun report(): Boolean {
                val b = map.boundingBox
                if (b != lastSent) {
                    lastSent = b
                    onBounds(b)
                }
                return false
            }
            override fun onScroll(event: ScrollEvent?) = report()
            override fun onZoom(event: ZoomEvent?) = report()
        }
        map.addMapListener(org.osmdroid.events.DelayedMapListener(listener, 300))
        onDispose {
            map.onPause()
        }
    }
    AndroidView({ map }, Modifier.fillMaxSize()) { m ->
        m.overlays.removeAll { it is Marker }
        if (home != null) {
            m.overlays.add(Marker(m).apply {
                position = GeoPoint(home.lat, home.lon)
                icon = icons.third
                title = "You"
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
            })
        }
        for (g in gateways) {
            m.overlays.add(Marker(m).apply {
                position = GeoPoint(g.latitude, g.longitude)
                val fm = filter != StationFilter.HF && g.channels.any { it.isFM }
                icon = if (fm) icons.second else icons.first
                title = g.callsign
                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                setOnMarkerClickListener { _, _ ->
                    onSelect(g)
                    true
                }
            })
        }
        m.invalidate()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StationDetailSheet(
    app: GatewayApplication,
    gateway: RMSGateway,
    channels: List<RMSChannel>,
    home: LatLon?,
    dismiss: () -> Unit,
    connected: () -> Unit,
) {
    val settings = app.settings
    val session = app.session
    val scope = rememberCoroutineScope()
    var tuning by remember { mutableStateOf<String?>(null) }
    var tuned by remember { mutableStateOf<String?>(null) }
    var tuneError by remember { mutableStateOf("") }

    /** Makes this channel the one to call, and moves the radio to it. */
    fun choose(c: RMSChannel) {
        settings.transportKind = TransportKind.VARA
        settings.select(gateway.callsign, c.dial.toLong())
        settings.mode = if (c.isFM) VARAMode.FM else VARAMode.HF
        c.bandwidth?.let { settings.bandwidth = it }
    }

    fun tune(c: RMSChannel) {
        if (session.running || tuning != null) return
        choose(c)
        tuneError = ""
        if (settings.rigMode == RigControlMode.OFF) {
            tuneError = "Radio control is off (Settings): tune to ${DialFrequency.format(c.dial.toLong())} yourself."
            return
        }
        tuning = c.id
        scope.launch {
            try {
                app.rig.prepare(c.dial.toLong(), if (c.isFM) RigMode.DATA_FM else RigMode.DATA_USB)
                tuned = c.id
            } catch (e: Exception) {
                tuned = null
                tuneError = "Could not tune the radio: ${e.message}"
            } finally {
                tuning = null
            }
        }
    }

    fun connect(c: RMSChannel) {
        choose(c)
        connected()
        session.start(app.store, app.rig)
    }

    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        LazyColumn(Modifier.padding(bottom = 24.dp)) {
            item {
                Text(gateway.callsign, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 28.dp))
            }
            section {
                if (home != null) {
                    val to = LatLon(gateway.latitude, gateway.longitude)
                    LabeledRow("Distance", "${Maidenhead.distance(home, to).toInt()} km, ${Maidenhead.bearing(home, to).toInt()}°")
                }
                channels.firstOrNull()?.grid?.takeIf { it.isNotEmpty() }?.let { LabeledRow("Grid", it) }
                gateway.lastStatus?.let { LabeledRow("Last heard by the CMS", it.dateTime()) }
                if (gateway.comments.isNotEmpty()) Text(gateway.comments, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 8.dp))
            }
            section(
                "Channels (dial frequency)",
                (if (tuneError.isNotEmpty()) "$tuneError\n" else "") + "Tap a channel to tune the radio to it. " + when {
                    settings.mycall.isEmpty() -> "Set your call sign in Settings first."
                    settings.rigMode == RigControlMode.OFF -> "Radio control is off: tune the radio to the dial frequency yourself before connecting."
                    else -> "Connect tunes the radio, sets the data mode and calls ${gateway.callsign}."
                },
            ) {
                for ((i, c) in channels.withIndex()) {
                    if (i > 0) RowDivider()
                    Row(
                        Modifier.fillMaxWidth().clickable { tune(c) }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (tuning == c.id) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(
                                if (tuned == c.id) Icons.Default.SettingsInputAntenna else Icons.Default.Radio, null,
                                tint = if (tuned == c.id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Column(Modifier.weight(1f)) {
                            Text("${DialFrequency.format(c.dial.toLong())} MHz", fontFamily = FontFamily.Monospace)
                            Text(
                                "${c.band} · ${c.modes}" + (if (c.hours.isEmpty()) "" else " · ${c.hours} UTC") + (if (c.antenna.isEmpty()) "" else " · ${c.antenna}"),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Button({ connect(c) }, enabled = !session.running && settings.mycall.isNotEmpty()) { Text("Connect") }
                    }
                }
            }
            item { Spacer(Modifier.width(1.dp)) }
        }
    }
}
