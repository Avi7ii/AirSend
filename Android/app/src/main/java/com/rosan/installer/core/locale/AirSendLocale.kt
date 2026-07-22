// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
package com.rosan.installer.core.locale

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class AirSendAppLanguage(val tag: String) {
    SimplifiedChinese("zh-CN"),
    English("en");

    companion object {
        fun fromTag(tag: String?): AirSendAppLanguage =
            fromTagOrNull(tag) ?: SimplifiedChinese

        fun fromTagOrNull(tag: String?): AirSendAppLanguage? {
            val locale = tag?.let(Locale::forLanguageTag) ?: return null
            return entries.firstOrNull {
                Locale.forLanguageTag(it.tag).language == locale.language
            }
        }
    }
}

data class AirSendLanguageRequest(
    val language: AirSendAppLanguage,
    val sequence: Long
)

object AirSendLocale {
    private const val PREFERENCES_NAME = "airsend_locale"
    private const val LANGUAGE_KEY = "language_v1"
    private val requestedLanguageState = MutableStateFlow(
        AirSendLanguageRequest(AirSendAppLanguage.SimplifiedChinese, sequence = 0L)
    )
    private val appliedLanguageState = MutableStateFlow(AirSendAppLanguage.SimplifiedChinese)

    val requestedLanguage = requestedLanguageState.asStateFlow()
    val appliedLanguage: AirSendAppLanguage
        get() = appliedLanguageState.value

    fun current(context: Context): AirSendAppLanguage {
        val savedTag = preferences(context).getString(LANGUAGE_KEY, null)
        AirSendAppLanguage.fromTagOrNull(savedTag)?.let { return it }

        // Android 13+ persists per-app locale independently. Treat it as the
        // migration source when upgrading from a build that did not yet write
        // AirSend's own preference, instead of incorrectly falling back to Chinese.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val localeManager = context.getSystemService(LocaleManager::class.java)
            AirSendAppLanguage.fromTagOrNull(
                localeManager.applicationLocales.get(0)?.toLanguageTag()
            )?.let { return it }
        }

        return AirSendAppLanguage.SimplifiedChinese
    }

    fun wrap(context: Context): Context {
        val locale = Locale.forLanguageTag(current(context).tag)
        val configuration = Configuration(context.resources.configuration).apply {
            setLocale(locale)
            setLocales(LocaleList(locale))
            setLayoutDirection(locale)
        }
        return context.createConfigurationContext(configuration)
    }

    fun applyCurrent(context: Context) {
        val language = current(context)
        persist(context, language)
        apply(context, language)
        requestedLanguageState.value = AirSendLanguageRequest(
            language = language,
            sequence = requestedLanguageState.value.sequence + 1L
        )
    }

    /**
     * Records the user's choice and lets the Compose host apply it at the
     * transparent midpoint of the language transition. Applying here would
     * make the visible tree relabel before the fade-out has begun.
     */
    fun set(context: Context, language: AirSendAppLanguage) {
        // A sequence makes every explicit selection an event. This also repairs
        // a stale state where Android already persisted one locale while the
        // current Compose tree is still displaying another one.
        persist(context, language)
        requestedLanguageState.value = AirSendLanguageRequest(
            language = language,
            sequence = requestedLanguageState.value.sequence + 1L
        )
    }

    /** Applies resources without recreating the current Activity. */
    fun apply(context: Context, language: AirSendAppLanguage) {
        applyConfiguration(context.applicationContext, language)
        if (context !== context.applicationContext) {
            applyConfiguration(context, language)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val localeManager = context.getSystemService(LocaleManager::class.java)
            val desired = LocaleList.forLanguageTags(language.tag)
            if (localeManager.applicationLocales.toLanguageTags() != desired.toLanguageTags()) {
                localeManager.applicationLocales = desired
            }
        }

        appliedLanguageState.value = language
    }

    fun configuration(
        base: Configuration,
        language: AirSendAppLanguage
    ): Configuration {
        val locale = Locale.forLanguageTag(language.tag)
        return Configuration(base).apply {
            setLocale(locale)
            setLocales(LocaleList(locale))
            setLayoutDirection(locale)
        }
    }

    @Suppress("DEPRECATION")
    private fun applyConfiguration(
        context: Context,
        language: AirSendAppLanguage
    ) {
        val configuration = configuration(context.resources.configuration, language)
        context.resources.updateConfiguration(
            configuration,
            context.resources.displayMetrics
        )
    }

    private fun preferences(context: Context) = storageContext(context).getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE
    )

    private fun storageContext(context: Context): Context =
        context.applicationContext ?: context

    private fun persist(context: Context, language: AirSendAppLanguage) {
        // Locale changes can synchronously dispatch a configuration callback.
        // Commit first so every context observes the same selection immediately.
        preferences(context)
            .edit()
            .putString(LANGUAGE_KEY, language.tag)
            .commit()
    }
}
