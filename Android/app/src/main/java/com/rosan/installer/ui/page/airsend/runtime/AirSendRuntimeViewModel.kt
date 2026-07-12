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
        dispatch(AirSendRuntimeAction.Refresh)
    }

    fun dispatch(action: AirSendRuntimeAction) {
        when (action) {
            AirSendRuntimeAction.Refresh -> refresh()
            AirSendRuntimeAction.StartService -> {
                repository.startService()
                refreshDelayed(R.string.airsend_service_started)
            }
            AirSendRuntimeAction.StopService -> {
                repository.stopService()
                refreshDelayed(R.string.airsend_service_stopped)
            }
            AirSendRuntimeAction.RestartService -> {
                repository.restartService()
                refreshDelayed(R.string.airsend_service_restarted)
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
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_clipboard_sent))
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
                    _events.emit(AirSendRuntimeEvent.ShowMessage(R.string.airsend_files_sent))
                    repository.refresh()
                }.onFailure {
                    _events.emit(AirSendRuntimeEvent.ShowRawMessage(it.message ?: "AirSend send failed"))
                    repository.refresh()
                }
            }
        }
    }

    private fun refresh() = viewModelScope.launch {
        repository.refresh()
    }

    private fun refreshDelayed(messageRes: Int) = viewModelScope.launch {
        _events.emit(AirSendRuntimeEvent.ShowMessage(messageRes))
        delay(300)
        repository.refresh()
    }
}
