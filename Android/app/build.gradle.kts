plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.airsend"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.airsend"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

val libsuVersion = "6.0.0"
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    
    // libsu
    implementation("com.github.topjohnwu.libsu:core:${libsuVersion}")
    implementation("com.github.topjohnwu.libsu:service:${libsuVersion}")
    implementation("com.github.topjohnwu.libsu:nio:${libsuVersion}")

    // Xposed API
    compileOnly("de.robv.android.xposed:api:82")
}
