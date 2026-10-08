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
// Some plugins still pin an old compileSdk - flutter_pcm_sound sits on 33,
// while its own androidx dependencies require 34 or later. This has to come
// before evaluationDependsOn(":app"), which evaluates the subprojects and
// makes a later afterEvaluate illegal.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { android ->
            if (android is com.android.build.gradle.BaseExtension) {
                android.compileSdkVersion(36)
                // AGP 9's built-in Kotlin defaults to JVM 17. Some plugins
                // still request Java 11, which fails target validation.
                android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
                android.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
