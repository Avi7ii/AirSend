// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.ui.page.airsend.runtime

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.rosan.installer.R
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch

class AirSendRuntimeViewModel(
    private val repository: AirSendRuntimeRepository
) : ViewModel() {
    val state = repository.state

    private val _events = MutableSharedFlow<AirSendRuntimeEvent>(
        replay = 0,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val events = _events.asSharedFlow()

    init {
        viewModelScope.launch { repository.refresh(showIndicator = false) }
    }

    fun dispatch(action: AirSendRuntimeAction) {
        when (action) {
            AirSendRuntimeAction.Refresh -> refresh()
            AirSendRuntimeAction.RefreshSilently -> viewModelScope.launch {
                repository.refresh(showIndicator = false)
            }
            AirSendRuntimeAction.DiscoverNow -> viewModelScope.launch {
                runCatching {
                    repository.discoverNow()
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_discovery_started))
                    delay(500)
                    repository.refresh(showIndicator = false)
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend discovery failed"
                        )
                    )
                    repository.refresh(showIndicator = false)
                }
            }
            AirSendRuntimeAction.StartService -> viewModelScope.launch {
                repository.startService()
                _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_service_started))
                delay(300)
                repository.refresh()
            }
            AirSendRuntimeAction.StopService -> viewModelScope.launch {
                repository.stopService()
                _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_service_stopped))
                delay(300)
                repository.refresh()
            }
            AirSendRuntimeAction.RestartService -> viewModelScope.launch {
                repository.restartService()
                _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_service_restarted))
                delay(300)
                repository.refresh()
            }
            AirSendRuntimeAction.RestartWholeService -> viewModelScope.launch {
                runCatching {
                    repository.restartWholeService()
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_whole_service_restarted))
                    delay(900)
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend whole service restart failed"
                        )
                    )
                    repository.refresh()
                }
            }
            AirSendRuntimeAction.RestartDaemon -> viewModelScope.launch {
                runCatching {
                    repository.restartDaemon()
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_daemon_restarting))
                    delay(1800)
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend daemon restart failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetBootStartEnabled -> {
                repository.setBootStartEnabled(action.enabled)
                refreshDelayed(
                    if (action.enabled) {
                        R.string.airsend_startup_enabled
                    } else {
                        R.string.airsend_startup_disabled
                    }
                )
            }
            is AirSendRuntimeAction.SetServiceNotificationEnabled -> viewModelScope.launch {
                runCatching {
                    repository.setServiceNotificationEnabled(action.enabled)
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend notification setting update failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SelectPeer -> viewModelScope.launch {
                runCatching {
                    repository.setPreferredTarget(action.targetId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_target_selected))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend target selection failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SendClipboardText -> viewModelScope.launch {
                runCatching {
                    repository.sendClipboardText(action.targetId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_transfer_queued))
                    repository.refresh()
                }.onFailure {
                    _events.emit(AirSendRuntimeEvent.ShowRawMessage(it.message ?: "AirSend send failed"))
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SendFiles -> viewModelScope.launch {
                runCatching {
                    repository.sendFiles(action.uris, action.targetId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_transfer_queued))
                    repository.refresh()
                }.onFailure {
                    _events.emit(AirSendRuntimeEvent.ShowRawMessage(it.message ?: "AirSend send failed"))
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.CancelTransfer -> viewModelScope.launch {
                runCatching {
                    repository.cancelTransfer(action.transferId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_cancel_requested))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend cancellation failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.RetryTransfer -> viewModelScope.launch {
                runCatching {
                    repository.retryTransfer(action.transferId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_transfer_queued))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend retry failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.AcceptTransfer -> viewModelScope.launch {
                runCatching {
                    repository.acceptTransfer(action.transferId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_transfer_accepted))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend acceptance failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.DeclineTransfer -> viewModelScope.launch {
                runCatching {
                    repository.declineTransfer(action.transferId)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_transfer_declined))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend decline failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SetReceivePolicy -> viewModelScope.launch {
                runCatching {
                    repository.setReceivePolicy(action.policy)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_receive_policy_updated))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend receive policy update failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SetClipboardSyncEnabled -> viewModelScope.launch {
                runCatching {
                    repository.setClipboardSyncEnabled(action.enabled)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend clipboard sync update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetScreenshotSyncEnabled -> viewModelScope.launch {
                runCatching {
                    repository.setScreenshotSyncEnabled(action.enabled)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend screenshot sync update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetHistoryLimitPerDirection -> viewModelScope.launch {
                runCatching {
                    repository.setHistoryLimitPerDirection(action.limit)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend history limit update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetTransportPreference -> viewModelScope.launch {
                runCatching {
                    repository.setTransportPreference(action.preference)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend transport update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetPeerTrusted -> viewModelScope.launch {
                runCatching {
                    repository.setPeerTrusted(action.fingerprint, action.trusted)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend trusted device update failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.SetDownloadDestination -> viewModelScope.launch {
                runCatching {
                    repository.setDownloadDestination(action.uri)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_save_location_updated))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend download location update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.SetMediaDestination -> viewModelScope.launch {
                runCatching {
                    repository.setMediaDestination(action.uri)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_save_location_updated))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend media location update failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.AddManualPeer -> viewModelScope.launch {
                runCatching {
                    repository.addManualPeer(
                        action.alias,
                        action.address,
                        action.port,
                        action.fingerprint
                    )
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_manual_peer_added))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend manual device probe failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.RemoveManualPeer -> viewModelScope.launch {
                runCatching {
                    repository.removeManualPeer(action.id)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_manual_peer_removed))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend manual device removal failed"
                        )
                    )
                    repository.refresh()
                }
            }
            is AirSendRuntimeAction.DeleteHistory -> viewModelScope.launch {
                runCatching {
                    repository.deleteHistory(action.id)
                }.onSuccess {
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend history deletion failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.ClearHistory -> viewModelScope.launch {
                runCatching {
                    repository.clearHistory(action.direction)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_history_cleared))
                    repository.refresh()
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend history clear failed"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.OpenReceivedFile -> {
                runCatching {
                    repository.openReceivedFile(action.path, action.mimeType)
                }.onFailure {
                    _events.tryEmit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "Unable to open received file"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.ShareReceivedFile -> {
                runCatching {
                    repository.shareReceivedFile(action.path, action.mimeType)
                }.onFailure {
                    _events.tryEmit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "Unable to share received file"
                        )
                    )
                }
            }
            is AirSendRuntimeAction.ExportLogs -> viewModelScope.launch {
                runCatching {
                    repository.exportLogs(action.uri)
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_logs_exported))
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend log export failed"
                        )
                    )
                }
            }
            AirSendRuntimeAction.ClearLogs -> viewModelScope.launch {
                runCatching {
                    repository.clearLogs()
                }.onSuccess {
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_logs_cleared))
                }.onFailure {
                    _events.emit(
                        AirSendRuntimeEvent.ShowRawMessage(
                            it.message ?: "AirSend log clear failed"
                        )
                    )
                }
            }
        }
    }

    private fun refresh() = viewModelScope.launch {
        repository.refresh(showIndicator = true)
    }

    private fun refreshDelayed(messageRes: Int) = viewModelScope.launch {
        _events.emit(AirSendRuntimeEvent.ShowMessage(messageRes))
        delay(300)
        repository.refresh()
    }
}
