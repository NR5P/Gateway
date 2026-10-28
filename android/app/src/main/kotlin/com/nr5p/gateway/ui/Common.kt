package com.nr5p.gateway.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** What a text field holds, so Android can pick a keyboard. */
enum class InputKind { CALLSIGN, EMAIL, URL, NUMBER, PLAIN }

fun InputKind.options(ime: ImeAction = ImeAction.Done) = when (this) {
    InputKind.CALLSIGN -> KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, imeAction = ime)
    InputKind.EMAIL -> KeyboardOptions(keyboardType = KeyboardType.Email, autoCorrectEnabled = false, imeAction = ime)
    InputKind.URL -> KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ime)
    InputKind.NUMBER -> KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ime)
    InputKind.PLAIN -> KeyboardOptions(autoCorrectEnabled = false, imeAction = ime)
}

/** A grouped form section, like the iOS ones: a header, rounded rows, a footer. */
fun LazyListScope.section(
    header: String? = null,
    footer: String? = null,
    footerColor: Color? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    item {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
            if (header != null) {
                Text(
                    header.uppercase(), style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp, bottom = 6.dp),
                )
            }
            Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp), content = content)
            }
            if (!footer.isNullOrEmpty()) {
                Text(
                    footer, style = MaterialTheme.typography.bodySmall,
                    color = footerColor ?: MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp),
                )
            }
        }
    }
}

@Composable
fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    kind: InputKind = InputKind.PLAIN,
    modifier: Modifier = Modifier,
    password: Boolean = false,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    minLines: Int = 1,
    monospace: Boolean = false,
) {
    var shown by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = singleLine,
        minLines = minLines,
        enabled = enabled,
        keyboardOptions = if (password) KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false) else kind.options(),
        visualTransformation = if (password && !shown) PasswordVisualTransformation() else VisualTransformation.None,
        trailingIcon = if (password) {
            { IconButton({ shown = !shown }) { Icon(if (shown) Icons.Default.VisibilityOff else Icons.Default.Visibility, "Show") } }
        } else null,
        textStyle = if (monospace) MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace) else MaterialTheme.typography.bodyLarge,
        modifier = modifier.fillMaxWidth().padding(vertical = 4.dp),
    )
}

@Composable
fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label)
        Spacer(Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun ToggleRow(label: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, Modifier.weight(1f))
        Switch(checked, onChange, enabled = enabled)
    }
}

/** A labelled drop-down picker, the counterpart of a SwiftUI menu Picker. */
@Composable
fun <T> PickerRow(label: String, value: T, options: List<Pair<T, String>>, enabled: Boolean = true, onChange: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().clickable(enabled = enabled) { open = true }.padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, Modifier.weight(1f))
            Text(
                options.firstOrNull { it.first == value }?.second ?: "",
                color = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Icon(Icons.Default.ArrowDropDown, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(open, { open = false }, Modifier.align(Alignment.TopEnd)) {
            for ((v, text) in options) {
                DropdownMenuItem(text = { Text(text) }, onClick = {
                    open = false
                    onChange(v)
                })
            }
        }
    }
}

@Composable
fun RowDivider() = HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

@Composable
fun Indicator(label: String, on: Boolean, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(if (on) color else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f)))
        Text(label, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
    }
    Spacer(Modifier.width(4.dp))
}

private val dateTime = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
private val dateOnly = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
private val shortDateTime = DateTimeFormatter.ofPattern("MMM d, HH:mm")
private val timeOnly = DateTimeFormatter.ofPattern("HH:mm:ss")

fun Instant.dateTime(): String = dateTime.format(atZone(ZoneId.systemDefault()))
fun Instant.dateOnly(): String = dateOnly.format(atZone(ZoneId.systemDefault()))
fun Instant.short(): String = shortDateTime.format(atZone(ZoneId.systemDefault()))
fun Instant.time(): String = timeOnly.format(atZone(ZoneId.systemDefault()))

fun byteCount(n: Int): String = when {
    n < 1000 -> "$n bytes"
    n < 1_000_000 -> String.format("%.1f KB", n / 1000.0)
    else -> String.format("%.1f MB", n / 1_000_000.0)
}
