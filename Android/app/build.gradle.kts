import com.mikepenz.aboutlibraries.plugin.DuplicateMode
import com.mikepenz.aboutlibraries.plugin.DuplicateRule
import java.util.Properties

plugins {
    alias(libs.plugins.installerx.application)
    alias(libs.plugins.ksp)
    alias(libs.plugins.room)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.aboutLibraries)
}

android {
    namespace = "com.rosan.installer"

    val properties = Properties()
    val keystorePropertiesFile = rootProject.file("keystore.properties")
    if (keystorePropertiesFile.exists()) {
        try {
            properties.load(keystorePropertiesFile.inputStream())
        } catch (e: Exception) {
            println("Warning: Could not load keystore.properties file: ${e.message}")
        }
    }
    val storeFile = properties.getProperty("storeFile") ?: System.getenv("KEYSTORE_FILE")
    val storePassword = properties.getProperty("storePassword") ?: System.getenv("KEYSTORE_PASSWORD")
    val keyAlias = properties.getProperty("keyAlias") ?: System.getenv("KEY_ALIAS")
    val keyPassword = properties.getProperty("keyPassword") ?: System.getenv("KEY_PASSWORD")
    val hasCustomSigning = storeFile != null && storePassword != null && keyAlias != null && keyPassword != null

    defaultConfig {
        applicationId = project.findProperty("APP_ID") as String? ?: "com.airsend"

        versionCode = 351
        versionName = "3.5.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("boolean", "INTERNET_ACCESS_ENABLED", "true")
        buildConfigField("int", "BUILD_LEVEL", "2")
    }

    signingConfigs {
        if (hasCustomSigning) {
            register("releaseCustom") {
                this.storeFile = rootProject.file(storeFile)
                this.storePassword = storePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = false
            }
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = if (hasCustomSigning) {
                println("Applying custom signing to debug build.")
                signingConfigs.getByName("releaseCustom")
            } else {
                println("No custom signing info. Debug build will use the default debug keystore.")
                signingConfigs.getByName("debug")
            }
            optimization.enable = false
        }
        getByName("release") {
            signingConfig = if (hasCustomSigning) {
                println("Applying custom signing to release build.")
                signingConfigs.getByName("releaseCustom")
            } else {
                println("No custom signing info. Release build will use the default debug keystore.")
                signingConfigs.getByName("debug")
            }
            vcsInfo.include = false
            optimization.enable = true
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    buildFeatures {
        buildConfig = true
        compose = true
        aidl = true
    }

    packaging {
        jniLibs {
            // Module-specific exclusions
            excludes += setOf(
                "lib/*/libandroidx.graphics.path.so",
                "lib/*/libdatastore_shared_counter.so"
            )
        }
    }

    androidResources {
        generateLocaleConfig = true
    }
}

configurations.all {
    exclude(group = "androidx.navigationevent", module = "navigationevent-compose")
}

aboutLibraries {
    library {
        // Enable the duplication mode, allows to merge, or link dependencies which relate
        duplicationMode = DuplicateMode.MERGE
        // Configure the duplication rule, to match "duplicates" with
        duplicationRule = DuplicateRule.SIMPLE
    }
}

room3 {
    // Specify the schema directory
    schemaDirectory("$projectDir/schemas")
}

dependencies {
    implementation(libs.androidx.profileinstaller)
    implementation(libs.android.tools.apksig)
    compileOnly(project(":hidden-api"))
    implementation(libs.androidx.core)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.lifecycle)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.splashscreen)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)

    implementation(libs.androidx.navigation3.runtime)
    // implementation(libs.androidx.navigation3.ui)
    implementation(libs.androidx.navigationevent) {
        exclude(group = "androidx.navigation", module = "navigationevent-compose")
    }

    implementation(libs.compose.materialIcons)
    // Preview support only for debug builds
    debugImplementation(libs.compose.ui.tooling)
    debugImplementation(libs.compose.ui.test.manifest)

    implementation(libs.room.runtime)
    ksp(libs.room.compiler)

    implementation(libs.ktx.serializationJson)

    implementation(libs.hiddenapibypass)

    implementation(platform(libs.koin.bom))
    implementation(libs.koin.core)
    implementation(libs.koin.android)
    implementation(libs.koin.compose)
    implementation(libs.koin.compose.viewmodel)

    implementation(libs.rikka.shizuku.api)
    implementation(libs.rikka.shizuku.provider)

    implementation(libs.appiconloader)

    implementation(libs.iamr0s.dhizuku.api)

    implementation(project(":app-process"))

    // aboutlibraries
    implementation(libs.aboutlibraries.core)
    implementation(libs.aboutlibraries.compose.m3)

    // log
    implementation(libs.timber)

    // miuix
    implementation(libs.miuix.core)
    implementation(libs.miuix.ui)
    implementation(libs.miuix.shader)
    implementation(libs.miuix.blur)
    implementation(libs.miuix.preference)
    implementation(libs.miuix.icons)
    implementation(libs.miuix.navigation)

    // okhttp
    implementation(platform(libs.okhttp.bom))
    implementation(libs.okhttp)

    // monetcompat
    implementation(libs.monetcompat)
    implementation(libs.androidx.palette)

    implementation(libs.focus.api)

    implementation(libs.materialKolor)

    compileOnly(files("libs/xposed-api-82.jar"))
}
