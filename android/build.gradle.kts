group = "io.github.aswinsubhash.native_feed_player"
version = "1.0-SNAPSHOT"

val media3Version = "1.11.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
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

android {
    namespace = "io.github.aswinsubhash.native_feed_player"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 1.11.0 brings DefaultPreloadManager, which preloads at the MediaSource
    // level instead of requiring a whole ExoPlayer per upcoming item.
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")
    implementation("androidx.media3:media3-database:$media3Version")

    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5:2.2.10")
    testImplementation("org.mockito:mockito-core:5.23.0")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.13.4")
    // Real-manager lifecycle tests run on the JVM through Robolectric.
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("junit:junit:4.13.2")
    testRuntimeOnly("org.junit.vintage:junit-vintage-engine:5.13.4")
    testImplementation("androidx.test:core:1.6.1")
}
