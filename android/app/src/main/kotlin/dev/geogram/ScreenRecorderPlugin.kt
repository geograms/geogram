package dev.geogram

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Screen recording plugin using MediaProjection API.
 *
 * Provides start/stop/isRecording methods via MethodChannel.
 * Recording runs in a foreground service (ScreenRecordForegroundService)
 * to hold the MediaProjection and satisfy Android's requirements.
 */
class ScreenRecorderPlugin(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "ScreenRecorderPlugin"
        private const val CHANNEL = "dev.geogram/screen_recorder"
        const val REQUEST_MEDIA_PROJECTION = 9001
    }

    private var methodChannel: MethodChannel? = null
    private var pendingOutputPath: String? = null
    private var pendingResult: MethodChannel.Result? = null

    fun initialize() {
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
        }
        Log.d(TAG, "ScreenRecorderPlugin initialized")
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val outputPath = call.argument<String>("outputPath")
                if (outputPath == null) {
                    result.error("INVALID_ARGUMENT", "outputPath is required", null)
                    return
                }
                startRecording(outputPath, result)
            }
            "stop" -> {
                stopRecording(result)
            }
            "isRecording" -> {
                result.success(ScreenRecordForegroundService.isRecording())
            }
            else -> result.notImplemented()
        }
    }

    private fun startRecording(outputPath: String, result: MethodChannel.Result) {
        if (ScreenRecordForegroundService.isRecording()) {
            result.error("ALREADY_RECORDING", "Recording is already in progress", null)
            return
        }

        pendingOutputPath = outputPath
        pendingResult = result

        val projectionManager = activity.getSystemService(
            Context.MEDIA_PROJECTION_SERVICE
        ) as MediaProjectionManager

        val intent = projectionManager.createScreenCaptureIntent()
        activity.startActivityForResult(intent, REQUEST_MEDIA_PROJECTION)
    }

    /**
     * Called from MainActivity.onActivityResult when the user grants/denies screen capture.
     */
    fun onProjectionResult(resultCode: Int, data: Intent?) {
        val result = pendingResult
        val outputPath = pendingOutputPath
        pendingResult = null
        pendingOutputPath = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.error("PERMISSION_DENIED", "Screen capture permission denied", null)
            return
        }

        if (outputPath == null) {
            result?.error("INVALID_STATE", "No output path set", null)
            return
        }

        // Start the foreground service with the projection data
        val serviceIntent = Intent(activity, ScreenRecordForegroundService::class.java).apply {
            action = "START"
            putExtra("resultCode", resultCode)
            putExtra("data", data)
            putExtra("outputPath", outputPath)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(serviceIntent)
        } else {
            activity.startService(serviceIntent)
        }

        result?.success(null)
    }

    private fun stopRecording(result: MethodChannel.Result) {
        if (!ScreenRecordForegroundService.isRecording()) {
            result.success(null)
            return
        }

        val outputPath = ScreenRecordForegroundService.getOutputPath()

        val serviceIntent = Intent(activity, ScreenRecordForegroundService::class.java).apply {
            action = "STOP"
        }
        activity.startService(serviceIntent)

        result.success(outputPath)
    }

    fun dispose() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }
}
