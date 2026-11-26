plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.linejaque.liquidyt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.linejaque.liquidyt"
        // yt-dlp (extractor / youtubedl-android) exige minSdk 24.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Native libs (.so) packaging — AGP 9, legacy DSL (the Flutter 3.47.9
    // scaffold sets android.newDsl=false, so `packagingOptions` is the
    // correct spelling here, not the new-DSL `packaging` block).
    packagingOptions {
        jniLibs {
            // AGP 9 forbids android:extractNativeLibs in the Manifest.
            // useLegacyPackaging=true is the documented DSL replacement
            // for extractNativeLibs=true: .so files are compressed in the
            // APK and extracted to the native lib dir at install time.
            // The extractor / youtubedl-android plugin REQUIRES this:
            // libpython.zip.so, libffmpeg.zip.so and libaria2c.zip.so
            // must exist as files on disk so the plugin can unzip and
            // execute Python / FFmpeg / aria2c at runtime.
            useLegacyPackaging = true
            // Those *.zip.so files are ZIP archives, not ELF objects:
            // llvm-strip fails on them ("not recognized as a valid
            // object file"). Never strip them.
            keepDebugSymbols += "**/*.zip.so"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // NOTE: do NOT set isExtractNativeLibs = false here.
            // AGP 9's packageRelease error suggests moving the manifest
            // setting into the build type, but false would mean the .so
            // files stay uncompressed inside the APK and are never
            // extracted — the extractor plugin would then fail at runtime
            // because libpython.zip.so etc. are not files on disk.
            // Extraction is preserved via useLegacyPackaging = true above.
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
