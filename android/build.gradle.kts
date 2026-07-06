group = "com.sixpages.six_pages_voice"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// Flutter 3.44 built-in Kotlin: under AGP >= 9 the Kotlin Android plugin is
// applied by the toolchain, so we must NOT re-apply it. Under AGP < 9 we apply
// it explicitly. This makes the plugin build on both. (Flutter plugin-author
// migration guide.)
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
if (agpMajor < 9) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.sixpages.six_pages_voice"

    compileSdk = 36

    // NDK r27 — must match the toolchain the prebuilt AEC3 archive was built
    // with in CI (produce-prebuilt.yml uses r27 / 27.0.12077973). The committed
    // prebuilt is arm64-v8a only (see abiFilters in defaultConfig).
    ndkVersion = "27.0.12077973"

    // Compile the AEC3 JNI shim and link it against the committed prebuilt.
    // Until this block exists, the cpp/ folder is inert (Gradle ignores it).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24

        // Only arm64-v8a is shipped. The committed prebuilt exists only for
        // this ABI; CMakeLists FATAL_ERRORs at configure time for any other.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

// Configure the Kotlin extension explicitly by class rather than via the
// top-level kotlin {} block. When the Kotlin Gradle Plugin is applied
// conditionally (above), the kotlin {} receiver is not available and causes a
// "receiver type mismatch" error. This project.extensions.configure form works
// whether KGP was applied conditionally or by the toolchain. (Flutter
// plugin-author migration guide, AGP <9 and >=9 support.)
project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}

