package com.nr5p.gateway

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.math.max

/** Makes a photo small enough to send over a radio link: scaled down, re-encoded as JPEG at the
 *  highest quality that fits the target size, upright, and without its metadata (no location).
 *  A full-size phone photo of 2-5 MB becomes about 20-30 KB, a minute or two at VARA HF speeds. */
object ImageShrinker {
    class Result(val data: ByteArray, val width: Int, val height: Int)

    /** The longest side to try, largest first, and the size to aim for. */
    val SIDES = listOf(640, 480, 320, 240)
    const val TARGET_BYTES = 30_000

    /** Null when [data] is not an image Android can decode. */
    fun shrink(data: ByteArray, target: Int = TARGET_BYTES): Result? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        // Decode at no more than about twice the largest size wanted, to keep memory down.
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= SIDES.first() * 2) sample *= 2
        val full = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val upright = rotate(full, orientation(data))
        var best: Result? = null
        for (side in SIDES) {
            val scale = side.toFloat() / max(upright.width, upright.height)
            val img = if (scale < 1f) {
                Bitmap.createScaledBitmap(upright, (upright.width * scale).toInt().coerceAtLeast(1), (upright.height * scale).toInt().coerceAtLeast(1), true)
            } else {
                upright
            }
            for (q in listOf(70, 55, 40, 30, 20)) {
                val out = ByteArrayOutputStream()
                img.compress(Bitmap.CompressFormat.JPEG, q, out)
                val r = Result(out.toByteArray(), img.width, img.height)
                if (best == null || r.data.size < best.data.size) best = r
                if (r.data.size <= target) return r
            }
        }
        return best
    }

    /** True for the image types worth shrinking (not, say, a small GIF or an SVG). */
    fun isPhoto(mime: String?): Boolean =
        mime != null && mime.startsWith("image/") && mime != "image/gif" && !mime.startsWith("image/svg")

    /** "IMG_1234.HEIC" -> "IMG_1234.jpg". */
    fun jpegName(name: String): String {
        val base = name.substringBeforeLast('.', name)
        return base.ifEmpty { "photo" } + ".jpg"
    }

    private fun orientation(data: ByteArray): Int = try {
        ExifInterface(ByteArrayInputStream(data)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }

    private fun rotate(b: Bitmap, orientation: Int): Bitmap {
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.postRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.postRotate(270f); m.postScale(-1f, 1f) }
            else -> return b
        }
        return Bitmap.createBitmap(b, 0, 0, b.width, b.height, m, true)
    }
}
