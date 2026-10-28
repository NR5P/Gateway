// WinlinkKit in plain Kotlin (no Android): the B2F protocol, LZHUF, the VARA
// and telnet transports and rig control. The app uses it; the unit tests run it
// on the JVM with the same test vectors as the Swift package.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    // Android has org.json built in; the JVM tests bring their own.
    compileOnly("org.json:json:20240303")
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

sourceSets["test"].resources.srcDir("../../WinlinkKit/Tests/WinlinkKitTests/Resources")
