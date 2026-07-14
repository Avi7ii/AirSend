package com.airsend

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.rosan.installer.R

data class AirSendShareTarget(
    val id: String,
    val alias: String,
    val deviceType: String? = null,
    val online: Boolean = true
)

object AirSendShareShortcutPublisher {
    const val CATEGORY = "com.airsend.category.DIRECT_SHARE_TARGET"
    const val SHORTCUT_PREFIX = "peer_"
    private const val ICON_REVISION = 5
    @Volatile
    private var lastPublishedSignature: String? = null

    @Synchronized
    fun publish(
        context: Context,
        targets: List<AirSendShareTarget>,
        preferredTargetId: String? = null
    ): Boolean {
        val rankedTargets = rankTargets(targets, preferredTargetId)
        // A temporary discovery gap must not erase the last useful Direct Share targets.
        if (rankedTargets.isEmpty()) return false

        val limit = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context)
            .coerceAtLeast(1)
        val publishedTargets = rankedTargets.take(limit)
        val signature = publishedTargets.joinToString(separator = "\u0000") {
            "$ICON_REVISION\u0001${it.id}\u0001${it.alias}\u0001${it.deviceType}" +
                "\u0001${it.id == preferredTargetId}"
        }
        if (signature == lastPublishedSignature) return false

        val shortcuts = publishedTargets.mapIndexed { rank, target ->
            ShortcutInfoCompat.Builder(context, shortcutId(target.id))
                .setShortLabel(target.alias)
                .setLongLabel(context.getString(R.string.airsend_send_to_peer, target.alias))
                .setIcon(AirSendShareIconFactory.create(context))
                .setCategories(setOf(CATEGORY))
                .setIntent(
                    Intent(Intent.ACTION_SEND)
                        .setClass(context, ShareTargetActivity::class.java)
                        .putExtra(ShareTargetActivity.EXTRA_TARGET_ID, target.id)
                        .putExtra(ShareTargetActivity.EXTRA_TARGET_ALIAS, target.alias)
                )
                .setRank(rank)
                .setLongLived(true)
                .build()
        }
        return ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts).also { published ->
            if (published) lastPublishedSignature = signature
        }
    }

    fun reportUsed(context: Context, targetId: String) {
        if (targetId.isBlank()) return
        ShortcutManagerCompat.reportShortcutUsed(context, shortcutId(targetId))
    }

    fun shortcutId(targetId: String): String = "$SHORTCUT_PREFIX$targetId"
}

internal fun rankTargets(
    targets: List<AirSendShareTarget>,
    preferredTargetId: String?
): List<AirSendShareTarget> = targets
    .asSequence()
    .filter { it.online && it.id.isNotBlank() && it.alias.isNotBlank() }
    .distinctBy { it.id }
    .sortedWith(
        compareByDescending<AirSendShareTarget> { it.id == preferredTargetId }
            .thenBy { it.alias.lowercase() }
            .thenBy { it.id }
    )
    .toList()
