package com.airsend

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity

/**
 * Exported share-sheet entry point.
 *
 * ColorOS forces activities launched directly from its share sheet into a flexible-window task.
 * Keep that task invisible and immediately hand the share to our own task, whose root activity is
 * [AirSendShareDialogActivity].
 */
class ShareTargetActivity : ComponentActivity() {
    companion object {
        const val EXTRA_TARGET_ID = "targetId"
        const val EXTRA_TARGET_ALIAS = "targetAlias"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sourceIntent = intent
        if (sourceIntent != null) {
            val launchDialog = PendingIntent.getActivity(
                this,
                0,
                Intent(sourceIntent).apply {
                    setClass(this@ShareTargetActivity, AirSendShareDialogActivity::class.java)
                    putExtra(AirSendShareDialogActivity.EXTRA_ORIGINAL_ACTION, sourceIntent.action)
                    action = AirSendShareDialogActivity.ACTION_SHOW_SHARE_DIALOG
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TASK or
                            Intent.FLAG_ACTIVITY_NO_ANIMATION or
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                },
                PendingIntent.FLAG_ONE_SHOT or
                    PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
            )

            // ColorOS propagates its share-sheet flexible-window state to activities launched
            // while this source task still exists. Remove the source first, then let the system
            // launch the real dialog without a flexible source task to link against.
            finishAndRemoveTask()
            overridePendingTransition(0, 0)
            launchDialog.send()
            return
        }

        overridePendingTransition(0, 0)
        finishAndRemoveTask()
    }
}

@Suppress("DEPRECATION")
internal fun Intent.shareUris(): List<Uri> = when (action) {
    Intent.ACTION_SEND -> listOfNotNull(getParcelableExtra(Intent.EXTRA_STREAM))
    Intent.ACTION_SEND_MULTIPLE ->
        getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    else -> emptyList()
}
