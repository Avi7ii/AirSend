// SPDX-License-Identifier: GPL-3.0-only
package com.rosan.installer.ui.page.airsend.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class AirSendFileClassifierTest {
    @Test
    fun appleJpegUtiAndImageExtensionAreRecognizedAsImages() {
        assertEquals(
            AirSendFileKind.Image,
            classifyAirSendFileKind("Screenshot_2026-07-13.jpg", "public.jpeg")
        )
        assertEquals(
            AirSendFileKind.Image,
            classifyAirSendFileKind("Screenshot_2026-07-13.jpg", "application/octet-stream")
        )
    }

    @Test
    fun standardMimeTypesAndExtensionsCoverTheVisibleFileFamilies() {
        assertEquals(AirSendFileKind.Image, classifyAirSendFileKind("photo", "image/png"))
        assertEquals(AirSendFileKind.Video, classifyAirSendFileKind("clip.mov", "public.movie"))
        assertEquals(AirSendFileKind.Audio, classifyAirSendFileKind("song.mp3", "public.mp3"))
        assertEquals(AirSendFileKind.Pdf, classifyAirSendFileKind("paper.pdf", "application/octet-stream"))
        assertEquals(AirSendFileKind.Archive, classifyAirSendFileKind("bundle.zip", "public.zip-archive"))
        assertEquals(AirSendFileKind.Code, classifyAirSendFileKind("Main.kt", "text/plain"))
        assertEquals(AirSendFileKind.Presentation, classifyAirSendFileKind("slides.pptx", "application/octet-stream"))
        assertEquals(AirSendFileKind.Spreadsheet, classifyAirSendFileKind("budget.xlsx", "application/octet-stream"))
        assertEquals(AirSendFileKind.WordProcessing, classifyAirSendFileKind("report.docx", "application/octet-stream"))
        assertEquals(AirSendFileKind.Html, classifyAirSendFileKind("index.html", "text/plain"))
        assertEquals(AirSendFileKind.Markdown, classifyAirSendFileKind("README.md", "text/plain"))
        assertEquals(AirSendFileKind.StructuredData, classifyAirSendFileKind("config.json", "text/plain"))
        assertEquals(AirSendFileKind.Text, classifyAirSendFileKind("notes.txt", "text/plain"))
        assertEquals(AirSendFileKind.Document, classifyAirSendFileKind("book.epub", "application/octet-stream"))
        assertEquals(AirSendFileKind.AndroidPackage, classifyAirSendFileKind("AirSend.apk", "application/octet-stream"))
        assertEquals(AirSendFileKind.Generic, classifyAirSendFileKind("payload.bin", "application/octet-stream"))
        assertEquals(AirSendFileKind.Multiple, classifyAirSendFileKind("", "", fileCount = 2))
    }
}
