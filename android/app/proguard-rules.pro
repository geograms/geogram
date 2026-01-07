# Flutter-specific rules (excluding Play Store deferred components for F-Droid)
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep Flutter embedding except PlayStore-specific classes
-keep class !io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager,!io.flutter.embedding.android.FlutterPlayStoreSplitApplication,io.flutter.embedding.** { *; }

# Suppress warnings for excluded classes
-dontwarn io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager
-dontwarn io.flutter.embedding.android.FlutterPlayStoreSplitApplication

# ============================================
# F-Droid compliance: Remove Google Play Core
# ============================================
# Suppress all warnings from Play Core
-dontwarn com.google.android.play.core.**

# Remove all Play Core classes entirely
-assumenosideeffects class com.google.android.play.core.** { *; }

# Specifically target the classes F-Droid flagged
-assumenosideeffects class com.google.android.play.core.splitinstall.** { *; }
-assumenosideeffects class com.google.android.play.core.splitcompat.** { *; }
-assumenosideeffects class com.google.android.play.core.tasks.** { *; }

# Tell R8 these classes don't exist and can be removed
-dontnote com.google.android.play.core.**

# TensorFlow Lite rules
-keep class org.tensorflow.** { *; }
-keep interface org.tensorflow.** { *; }
-dontwarn org.tensorflow.**
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options

# ONNX Runtime rules
-keep class ai.onnxruntime.** { *; }

# Keep TFLite Flutter plugin
-keep class com.tfliteflutter.** { *; }
-dontwarn com.tfliteflutter.**
