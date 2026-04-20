allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Compatibility shims for older Flutter plugins that haven't caught
// up with AGP 8 / Kotlin 2.x. We:
//   * inject a `namespace` derived from the legacy <manifest package>
//     attribute when the plugin doesn't declare one — required by AGP 8+.
//   * align Java + Kotlin JVM targets to 17 so plugins relying on
//     defaults don't trip "Inconsistent JVM Target Compatibility".
//   * pin an NDK for plugins that need a specific one.
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            val android = project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            try {
                val getNs = android.javaClass.getMethod("getNamespace")
                val current = getNs.invoke(android) as String?
                if (current.isNullOrEmpty()) {
                    val manifestFile = android.sourceSets.getByName("main").manifest.srcFile
                    if (manifestFile.exists()) {
                        val pkg = Regex("""package\s*=\s*"([^"]+)"""")
                            .find(manifestFile.readText())
                            ?.groupValues?.get(1)
                        if (!pkg.isNullOrEmpty()) {
                            android.javaClass
                                .getMethod("setNamespace", String::class.java)
                                .invoke(android, pkg)
                        }
                    }
                }
            } catch (_: NoSuchMethodException) {
                // Older AGP without the namespace API — nothing to do.
            }

            android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
            android.compileOptions.targetCompatibility = JavaVersion.VERSION_17

            if (project.name == "whisper_flutter_new") {
                android.ndkVersion = "28.2.13676358"
            }
        }

        // Align Kotlin JVM target with Java for every Kotlin task so
        // older plugins stop picking up the host JDK's version by
        // default (which caused "Inconsistent JVM target" for
        // shared_storage).
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
