// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.airsend.AirSendShareShortcutPublisher
import com.airsend.shareUris
import com.rosan.installer.R
import com.rosan.installer.ui.icons.AppIcons
import com.rosan.installer.ui.page.airsend.runtime.AirSendRuntimeRepository
import com.rosan.installer.ui.page.main.installer.components.PositionDialog
import kotlinx.coroutines.launch

/**
 * Material 3 share dialog hosted by the same translucent, single-instance activity strategy
 * used by InstallerX Revived's installer dialog.
 */
@Composable
fun AirSendShareTargetDialog(
    shareIntent: Intent,
    preferredTargetId: String?,
    repository: AirSendRuntimeRepository,
    onDismiss: () -> Unit,
    onSent: () -> Unit
) {
    val context = LocalContext.current
    val state by repository.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var selectedTargetId by remember(shareIntent, preferredTargetId) {
        mutableStateOf(preferredTargetId)
    }
    var sendingTarget by remember { mutableStateOf<String?>(null) }
    var sentTargetAlias by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(shareIntent) {
        repository.refresh()
        if (repository.state.value.peers.none { it.online }) {
            runCatching { repository.discoverNow() }
            repository.refresh()
        }
        if (repository.state.value.peers.none { it.online && it.id == selectedTargetId }) {
            selectedTargetId = null
        }
    }

    val onlinePeers = state.peers.filter { it.online }
    val selectedPeer = onlinePeers.firstOrNull { it.id == selectedTargetId }
    val isSending = sendingTarget != null
    val isFinished = sentTargetAlias != null

    PositionDialog(
        modifier = Modifier.fillMaxWidth(),
        properties = DialogProperties(
            dismissOnBackPress = !isSending,
            dismissOnClickOutside = !isSending
        ),
        useBlur = true,
        onDismissRequest = {
            if (!isSending) onDismiss()
        },
        centerIcon = {
            val iconColor = if (isFinished) {
                MaterialTheme.colorScheme.tertiaryContainer
            } else {
                MaterialTheme.colorScheme.primaryContainer
            }
            val contentColor = if (isFinished) {
                MaterialTheme.colorScheme.onTertiaryContainer
            } else {
                MaterialTheme.colorScheme.onPrimaryContainer
            }
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(iconColor),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (isFinished) AppIcons.Active else AppIcons.Share,
                    contentDescription = null,
                    modifier = Modifier.size(36.dp),
                    tint = contentColor
                )
            }
        },
        centerTitle = {
            Text(
                text = if (isFinished) {
                    stringResource(R.string.airsend_share_started_to, sentTargetAlias.orEmpty())
                } else {
                    stringResource(R.string.airsend_share_choose_target)
                },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        },
        centerContent = {
            if (!isFinished) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 380.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (onlinePeers.isEmpty()) {
                        Text(
                            text = stringResource(R.string.airsend_share_no_target_desc),
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    } else {
                        onlinePeers.forEach { peer ->
                            val selected = peer.id == selectedTargetId
                            Surface(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp)
                                    .clip(RoundedCornerShape(20.dp))
                                    .clickable(enabled = !isSending) {
                                        selectedTargetId = peer.id
                                        error = null
                                    },
                                shape = RoundedCornerShape(20.dp),
                                color = if (selected) {
                                    MaterialTheme.colorScheme.secondaryContainer
                                } else {
                                    MaterialTheme.colorScheme.surfaceContainer
                                }
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                                ) {
                                    Icon(
                                        imageVector = when (peer.deviceType?.lowercase()) {
                                            "mobile", "phone" -> AppIcons.DevicePhone
                                            "tablet" -> AppIcons.DeviceTablet
                                            "laptop" -> AppIcons.DeviceLaptop
                                            "desktop" -> AppIcons.DeviceDesktop
                                            "tv" -> AppIcons.DeviceTv
                                            else -> AppIcons.DeviceOther
                                        },
                                        contentDescription = null,
                                        modifier = Modifier.size(28.dp),
                                        tint = MaterialTheme.colorScheme.primary
                                    )
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = peer.alias,
                                            style = MaterialTheme.typography.titleMedium,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        val summary = listOf(peer.deviceModel, peer.address)
                                            .filter(String::isNotBlank)
                                            .joinToString(" · ")
                                        if (summary.isNotBlank()) {
                                            Text(
                                                text = summary,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                    RadioButton(
                                        selected = selected,
                                        enabled = !isSending,
                                        onClick = {
                                            selectedTargetId = peer.id
                                            error = null
                                        }
                                    )
                                }
                            }
                        }
                    }

                    error?.let { message ->
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = stringResource(R.string.airsend_share_failed_with_reason, message),
                            modifier = Modifier.padding(horizontal = 16.dp),
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
            }
        },
        leftButton = if (!isFinished) {
            {
                TextButton(enabled = !isSending, onClick = onDismiss) {
                    Text(stringResource(R.string.cancel))
                }
            }
        } else {
            null
        },
        rightButton = {
            if (isFinished) {
                TextButton(onClick = onSent) {
                    Text(stringResource(R.string.finish))
                }
            } else {
                TextButton(
                    enabled = selectedPeer != null && !isSending,
                    onClick = {
                        val target = selectedPeer ?: return@TextButton
                        sendingTarget = target.id
                        error = null
                        scope.launch {
                            runCatching {
                                val uris = shareIntent.shareUris()
                                if (uris.isNotEmpty()) {
                                    repository.sendFiles(uris, target.id)
                                } else {
                                    val text = shareIntent
                                        .getStringExtra(Intent.EXTRA_TEXT)
                                        ?.takeIf(String::isNotBlank)
                                        ?: error("Nothing to share")
                                    repository.sendText(text, target.id)
                                }
                            }.onSuccess {
                                AirSendShareShortcutPublisher.reportUsed(context, target.id)
                                sentTargetAlias = target.alias
                                sendingTarget = null
                            }.onFailure {
                                error = it.message ?: "AirSend transfer failed"
                                sendingTarget = null
                            }
                        }
                    }
                ) {
                    Text(
                        text = if (isSending && selectedPeer != null) {
                            stringResource(R.string.airsend_share_sending_to, selectedPeer.alias)
                        } else {
                            stringResource(R.string.airsend_share_send)
                        }
                    )
                }
            }
        }
    )
}
