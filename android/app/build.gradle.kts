import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyProperties = Properties()
val releaseKeyFile = rootProject.file("key.properties")
if (releaseKeyFile.exists()) releaseKeyFile.inputStream().use { releaseKeyProperties.load(it) }
fun releaseKey(name: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotEmpty() } ?: releaseKeyProperties.getProperty(name)
val releaseKeyPath = releaseKey("storeFile", "HOME_LISTEN_KEYSTORE_FILE")
val releaseKeyPassword = releaseKey("storePassword", "HOME_LISTEN_STORE_PASSWORD")
val releaseKeyAlias = releaseKey("keyAlias", "HOME_LISTEN_KEY_ALIAS")
val releaseAliasPassword = releaseKey("keyPassword", "HOME_LISTEN_KEY_PASSWORD")
val releaseKeyReady = listOf(releaseKeyPath, releaseKeyPassword, releaseKeyAlias, releaseAliasPassword)
    .all { !it.isNullOrEmpty() } && rootProject.file(releaseKeyPath!!).isFile
if (System.getenv("HOME_LISTEN_REQUIRE_RELEASE_SIGNING") == "true" && !releaseKeyReady) {
    throw GradleException("A permanent Home Listen release key is required. See docs/ANDROID_RELEASE.md.")
}

android {
    namespace = "com.wiantribe.home_listen"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.wiantribe.home_listen"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // opus_flutter ships native code the NDK rejects below API 21, and the
        // recorder needs 23; every phone this is meant for is far newer.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeyReady) create("permanentRelease") {
            storeFile = rootProject.file(releaseKeyPath!!)
            storePassword = releaseKeyPassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseAliasPassword
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeyReady) "permanentRelease" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("io.github.webrtc-sdk:android:150.7871.01")
    implementation("com.google.firebase:firebase-common:22.0.1")
    testImplementation("junit:junit:4.13.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
