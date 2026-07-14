package com.airsend

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.core.graphics.drawable.IconCompat
import kotlin.math.roundToInt

internal object AirSendShareIconFactory {
    private const val ICON_SIZE = 216
    private const val APP_ICON_SCALE = 0.85f

    fun create(context: Context): IconCompat {
        val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        val inset = ((ICON_SIZE * (1f - APP_ICON_SCALE)) / 2f).roundToInt()
        context.applicationInfo.loadIcon(context.packageManager).apply {
            setBounds(inset, inset, ICON_SIZE - inset, ICON_SIZE - inset)
            draw(Canvas(bitmap))
        }
        // Direct Share applies its own circular mask. Supplying an adaptive icon here makes the
        // system enlarge the already-scaled artwork a second time and crops its outer edges.
        return IconCompat.createWithBitmap(bitmap)
    }
}
