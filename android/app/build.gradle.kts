import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load key.properties if it exists
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "dev.geogram"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Disable dependency metadata for F-Droid compliance
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.geogram"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// Exclude Google Play Core for F-Droid compliance
configurations.all {
    exclude(group = "com.google.android.play", module = "core")
    exclude(group = "com.google.android.play", module = "core-common")
    exclude(group = "com.google.android.play", module = "core-ktx")
    exclude(group = "com.google.android.play", module = "feature-delivery")
    exclude(group = "com.google.android.play", module = "feature-delivery-ktx")
    exclude(group = "com.google.android.play", module = "app-update")
    exclude(group = "com.google.android.play", module = "app-update-ktx")
    exclude(group = "com.google.android.play", module = "review")
    exclude(group = "com.google.android.play", module = "review-ktx")
    exclude(group = "com.google.android.play", module = "asset-delivery")
    exclude(group = "com.google.android.play", module = "asset-delivery-ktx")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
