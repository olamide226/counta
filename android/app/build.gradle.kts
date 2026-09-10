import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// --- Upload-key signing ------------------------------------------------------
//
// Release builds are signed with the *upload* key, not the app signing key:
// Play App Signing holds the key that actually signs what users install, and
// this one only proves to Google that an upload came from us. See
// docs/RELEASE-BACKGROUND.md for how to create it and why that matters.
//
// The material lives in android/key.properties, which is gitignored along with
// *.jks / *.keystore. This is a public repository — nothing here may read a
// secret that is committed.
val keystorePropertiesFile: File = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

/**
 * Every field must be present; a half-filled file is a mistake, not a fallback.
 *
 * No separate existence check: when the file is absent nothing was loaded, so
 * every getProperty is null and `all` is already false.
 */
val uploadKeyFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasUploadKey: Boolean =
    uploadKeyFields.all { !keystoreProperties.getProperty(it).isNullOrBlank() }

/**
 * Set by `make build-appbundle` (as ORG_GRADLE_PROJECT_requireReleaseSigning).
 *
 * A contributor running `flutter run --release` should not need a keystore, so
 * the default is a debug-signed fallback. A build that is meant for the Play
 * Console must never silently take that fallback — Play rejects the upload
 * hours later with an unhelpful message — so the store-bound targets ask for a
 * hard failure here instead.
 *
 * It gates on all four fields above rather than on the file existing, which is
 * the failure that actually happens: a key.properties copied from the example
 * and only half filled in reads as "configured" to anything that just stats
 * the path, and then signs with nothing.
 */
val requireReleaseSigning: Boolean =
    (project.findProperty("requireReleaseSigning") as String?)?.toBoolean() ?: false

if (!hasUploadKey && requireReleaseSigning) {
    throw GradleException(
        buildString {
            appendLine("No upload key configured, but this build is marked as store-bound.")
            appendLine("Expected android/key.properties with: ${uploadKeyFields.joinToString(", ")}")
            appendLine("Copy android/key.properties.example and fill it in.")
            append("See docs/RELEASE-BACKGROUND.md, 'Android release signing'.")
        },
    )
}

if (!hasUploadKey) {
    logger.lifecycle(
        "counta: no upload key in android/key.properties — release builds will be " +
            "signed with the debug key. Fine for `flutter run --release`; NOT " +
            "uploadable to Play.",
    )
}

android {
    namespace = "com.ruachtech.counta"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.ruachtech.counta"
        // Android package names cannot contain a hyphen, so this deliberately
        // differs from the iOS bundle id com.ruach-tech.counta. Both are the
        // published identity of the same app and neither can ever change.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                // rootProject is android/, where key.properties lives, so a
                // relative storeFile resolves against it and an absolute one
                // is returned unchanged.
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The debug fallback keeps `flutter run --release` working without
            // a keystore; store-bound builds never reach it, because
            // requireReleaseSigning has already failed the configuration above.
            signingConfig = signingConfigs.getByName(if (hasUploadKey) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
