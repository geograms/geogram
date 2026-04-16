allprojects {
    repositories {
        google()
        mavenCentral()
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
// Old pub.dev plugins (e.g. wasm_run_flutter 0.1.0) predate AGP 8's
// mandatory `namespace` field. Inject it at plugin-apply time so it
// lands before evaluation.
subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.findByName("android")
        if (android is com.android.build.gradle.LibraryExtension) {
            if (android.namespace.isNullOrEmpty()) {
                android.namespace = project.group.toString()
                        .ifEmpty { "com.example.${project.name.replace("-", "_")}" }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
