package dev.geogram

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * USB AOA (Android Open Accessory) plugin for device-to-device communication
 *
 * Provides:
 * - Accessory mode detection and connection
 * - Bidirectional data transfer via bulk endpoints
 * - Permission handling
 * - Connection state management
 *
 * Note: AOA requires at least one device with USB OTG capability.
 * The OTG-capable device becomes the "host" and initiates the AOA handshake.
 */
class UsbAoaPlugin(
    private val context: Context,
    private val flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "UsbAoaPlugin"
        private const val CHANNEL = "geogram/usb_aoa"
        private const val ACTION_USB_PERMISSION = "dev.geogram.USB_PERMISSION"

        // Buffer size for bulk transfers (16KB is optimal for USB 2.0 HS)
        private const val BUFFER_SIZE = 16384

        // AOA identification strings
        private const val MANUFACTURER = "Geogram"
        private const val MODEL = "Geogram Device"
        private const val DESCRIPTION = "Geogram USB Communication"
        private const val VERSION = "1.0"
        private const val URI = "https://geogram.radio"
        private const val SERIAL = "geogram-aoa"
    }

    private var methodChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()

    private var usbManager: UsbManager? = null
    private var accessory: UsbAccessory? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var inputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null

    private val isConnected = AtomicBoolean(false)
    private val isReading = AtomicBoolean(false)
    private val isDisposed = AtomicBoolean(false)

    /// Flag to track if handleAccessoryAttached was already called (prevents double-open race)
    private val alreadyAttached = AtomicBoolean(false)

    private var permissionReceiver: BroadcastReceiver? = null
    private var detachReceiver: BroadcastReceiver? = null
    private var attachReceiver: BroadcastReceiver? = null

    /**
     * Initialize the plugin and set up method channel
     */
    fun initialize() {
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
        }

        usbManager = context.getSystemService(Context.USB_SERVICE) as? UsbManager

        // Register receivers
        registerPermissionReceiver()
        registerDetachReceiver()
        registerAttachReceiver()

        Log.d(TAG, "UsbAoaPlugin initialized, USB manager available: ${usbManager != null}")

        // Delay accessory check to let activity fully initialize
        // Skip if handleAccessoryAttached was already called (cold start via USB_ACCESSORY_ATTACHED intent)
        mainHandler.postDelayed({
            if (alreadyAttached.get()) {
                Log.d(TAG, "Skipping delayed accessory check - already attached via intent")
                return@postDelayed
            }
            if (isDisposed.get()) {
                Log.d(TAG, "Skipping delayed accessory check - plugin disposed")
                return@postDelayed
            }
            Log.d(TAG, "Checking for existing accessory (delayed)...")
            checkForExistingAccessory()
        }, 500)
    }

    /**
     * Clean up resources
     */
    fun dispose() {
        if (isDisposed.getAndSet(true)) {
            Log.w(TAG, "dispose() called but already disposed")
            return
        }
        close()
        stopAccessoryPolling()
        unregisterReceivers()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        executor.shutdown()
    }

    /**
     * Safely execute a task on the executor, ignoring if disposed or shutdown
     */
    private fun safeExecute(task: () -> Unit) {
        if (isDisposed.get() || executor.isShutdown) {
            Log.d(TAG, "Ignoring task - executor is shutdown or disposed")
            return
        }
        try {
            executor.execute(task)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to execute task: ${e.message}")
        }
    }

    /**
     * Handle method calls from Dart
     */
    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (isDisposed.get()) {
            Log.w(TAG, "handleMethodCall(${call.method}) ignored - plugin disposed")
            result.error("DISPOSED", "UsbAoaPlugin has been disposed", null)
            return
        }

        when (call.method) {
            "initialize" -> {
                result.success(usbManager != null)
            }

            "open" -> {
                openAccessory(result)
            }

            "close" -> {
                close()
                result.success(true)
            }

            "write" -> {
                Log.d(TAG, "Write method called from Dart")
                val data = call.argument<ByteArray>("data")
                if (data != null) {
                    Log.d(TAG, "Write: data size = ${data.size}, isConnected = ${isConnected.get()}")
                    write(data, result)
                } else {
                    Log.e(TAG, "Write: data is null!")
                    result.error("INVALID_ARGUMENT", "Data required", null)
                }
            }

            "isConnected" -> {
                result.success(isConnected.get())
            }

            "hasPermission" -> {
                val hasPermission = accessory?.let { usbManager?.hasPermission(it) } ?: false
                result.success(hasPermission)
            }

            "requestPermission" -> {
                requestPermission(result)
            }

            "getAccessoryInfo" -> {
                val info = accessory?.let {
                    mapOf(
                        "manufacturer" to it.manufacturer,
                        "model" to it.model,
                        "description" to it.description,
                        "version" to it.version,
                        "uri" to it.uri,
                        "serial" to safeGetSerial(it)
                    )
                }
                result.success(info)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Handle USB accessory attached intent (called from MainActivity)
     */
    fun handleAccessoryAttached(accessory: UsbAccessory) {
        if (isDisposed.get()) {
            Log.w(TAG, "handleAccessoryAttached ignored - plugin disposed")
            return
        }

        Log.d(TAG, "handleAccessoryAttached: ${accessory.manufacturer} ${accessory.model}")
        alreadyAttached.set(true)
        this.accessory = accessory

        // Check if we have permission
        val hasPermission = usbManager?.hasPermission(accessory) == true
        Log.d(TAG, "hasPermission=$hasPermission for accessory")

        if (hasPermission) {
            // Open immediately
            Log.d(TAG, "Opening accessory immediately (permission granted)")
            safeExecute {
                val success = openAccessoryInternal()
                Log.d(TAG, "openAccessoryInternal returned: $success")
                mainHandler.post {
                    if (success) {
                        notifyConnected(accessory)
                    }
                }
            }
        } else {
            // Request permission
            Log.d(TAG, "Requesting permission for accessory")
            requestPermissionForAccessory(accessory)
        }
    }

    /**
     * Open the USB accessory connection
     */
    private fun openAccessory(result: MethodChannel.Result) {
        val currentAccessory = accessory
        if (currentAccessory == null) {
            // Try to find an available accessory
            val accessories = usbManager?.accessoryList
            if (accessories.isNullOrEmpty()) {
                result.error("NO_ACCESSORY", "No USB accessory connected", null)
                return
            }
            accessory = accessories[0]
        }

        // Check permission
        if (usbManager?.hasPermission(accessory!!) != true) {
            result.error("NO_PERMISSION", "USB permission not granted", null)
            return
        }

        safeExecute {
            val success = openAccessoryInternal()
            mainHandler.post {
                if (success) {
                    result.success(true)
                } else {
                    result.error("OPEN_FAILED", "Failed to open USB accessory", null)
                }
            }
        }
    }

    /**
     * Open the accessory connection (internal, runs on background thread)
     */
    private fun openAccessoryInternal(): Boolean {
        Log.d(TAG, "openAccessoryInternal: starting")
        val currentAccessory = accessory
        if (currentAccessory == null) {
            Log.e(TAG, "openAccessoryInternal: accessory is null!")
            return false
        }
        Log.d(TAG, "openAccessoryInternal: accessory=${currentAccessory.manufacturer} ${currentAccessory.model}")

        try {
            // Close any existing connection
            closeInternal()

            // Open the accessory
            Log.d(TAG, "openAccessoryInternal: calling usbManager.openAccessory...")
            fileDescriptor = usbManager?.openAccessory(currentAccessory)
            if (fileDescriptor == null) {
                Log.e(TAG, "openAccessoryInternal: fileDescriptor is null! (openAccessory failed)")
                return false
            }
            Log.d(TAG, "openAccessoryInternal: got fileDescriptor")

            val fd = fileDescriptor!!.fileDescriptor
            Log.d(TAG, "openAccessoryInternal: fd.valid=${fd.valid()}")
            inputStream = FileInputStream(fd)
            outputStream = FileOutputStream(fd)

            isConnected.set(true)
            resetAutoReconnect()
            Log.d(TAG, "USB accessory opened successfully")

            // Wait for USB endpoints to synchronize before starting I/O
            // This gives the host (Linux) time to also open the device
            // Reduced from 2000ms to 500ms as the Linux side now waits properly
            Log.d(TAG, "Waiting 500ms for USB endpoints to synchronize...")
            Thread.sleep(500)
            Log.d(TAG, "Starting read thread")

            // Start reading thread
            startReading()

            return true
        } catch (e: Exception) {
            Log.e(TAG, "Error opening accessory: ${e.message}", e)
            closeInternal()
            return false
        }
    }

    /**
     * Close the accessory connection
     */
    private fun close() {
        safeExecute {
            closeInternal()
            mainHandler.post {
                notifyDisconnected()
            }
        }
    }

    /**
     * Close the accessory connection (internal)
     */
    private fun closeInternal() {
        isReading.set(false)
        isConnected.set(false)

        try {
            inputStream?.close()
        } catch (e: IOException) {
            Log.e(TAG, "Error closing input stream: ${e.message}")
        }
        inputStream = null

        try {
            outputStream?.close()
        } catch (e: IOException) {
            Log.e(TAG, "Error closing output stream: ${e.message}")
        }
        outputStream = null

        try {
            fileDescriptor?.close()
        } catch (e: IOException) {
            Log.e(TAG, "Error closing file descriptor: ${e.message}")
        }
        fileDescriptor = null

        Log.d(TAG, "USB accessory closed")
    }

    /**
     * Write data to the accessory
     */
    private fun write(data: ByteArray, result: MethodChannel.Result) {
        Log.d(TAG, "write() called: dataSize=${data.size}, isConnected=${isConnected.get()}, isDisposed=${isDisposed.get()}, executorShutdown=${executor.isShutdown}")
        if (!isConnected.get()) {
            Log.e(TAG, "write() - NOT_CONNECTED error")
            result.error("NOT_CONNECTED", "USB accessory not connected", null)
            return
        }

        Log.d(TAG, "write() - scheduling safeExecute")
        safeExecute {
            Log.d(TAG, "write() - inside safeExecute task")
            val success = writeInternal(data)
            Log.d(TAG, "write() - writeInternal returned: $success")
            mainHandler.post {
                Log.d(TAG, "write() - posting result to main handler, success=$success")
                if (success) {
                    result.success(true)
                } else {
                    result.error("WRITE_FAILED", "Failed to write to USB accessory", null)
                }
            }
        }
        Log.d(TAG, "write() - safeExecute scheduled")
    }

    /**
     * Write data to the accessory (internal)
     */
    private fun writeInternal(data: ByteArray): Boolean {
        Log.d(TAG, "writeInternal() called: dataSize=${data.size}, outputStream=${outputStream != null}")
        return try {
            Log.d(TAG, "writeInternal() calling outputStream.write...")
            outputStream?.write(data)
            Log.d(TAG, "writeInternal() calling outputStream.flush...")
            outputStream?.flush()
            Log.d(TAG, "Wrote ${data.size} bytes to USB accessory")
            true
        } catch (e: IOException) {
            Log.e(TAG, "Error writing to accessory: ${e.message}", e)
            // Connection likely lost
            closeInternal()
            mainHandler.post { notifyDisconnected() }
            false
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected error in writeInternal: ${e.message}", e)
            false
        }
    }

    /**
     * Start the reading thread
     */
    private fun startReading() {
        if (isReading.getAndSet(true)) {
            return // Already reading
        }

        safeExecute {
            val buffer = ByteArray(BUFFER_SIZE)

            while (isReading.get() && isConnected.get()) {
                try {
                    val bytesRead = inputStream?.read(buffer) ?: -1
                    if (bytesRead == -1) {
                        Log.d(TAG, "End of stream reached")
                        break
                    }

                    if (bytesRead > 0) {
                        val data = buffer.copyOf(bytesRead)
                        Log.d(TAG, "Received ${bytesRead} bytes from USB accessory")
                        mainHandler.post {
                            notifyDataReceived(data)
                        }
                    }
                } catch (e: IOException) {
                    if (isReading.get()) {
                        Log.e(TAG, "Error reading from accessory: ${e.message}")
                    }
                    break
                }
            }

            // Connection ended
            if (isConnected.getAndSet(false)) {
                closeInternal()
                mainHandler.post {
                    notifyDisconnected()
                    // Schedule auto-reconnect after unexpected disconnect
                    scheduleAutoReconnect()
                }
            }
            isReading.set(false)
        }
    }

    private var autoReconnectAttempts = 0
    private val maxAutoReconnectAttempts = 3

    /**
     * Schedule auto-reconnect with exponential backoff
     */
    private fun scheduleAutoReconnect() {
        if (isDisposed.get()) return
        if (autoReconnectAttempts >= maxAutoReconnectAttempts) {
            Log.d(TAG, "Max auto-reconnect attempts reached ($maxAutoReconnectAttempts)")
            autoReconnectAttempts = 0
            return
        }

        autoReconnectAttempts++
        // Exponential backoff: 1s, 2s, 4s
        val delayMs = 1000L * (1 shl (autoReconnectAttempts - 1))
        Log.d(TAG, "Scheduling auto-reconnect attempt $autoReconnectAttempts in ${delayMs}ms")

        mainHandler.postDelayed({
            if (!isConnected.get() && !isDisposed.get()) {
                Log.d(TAG, "Auto-reconnect attempt $autoReconnectAttempts")
                // Check for existing accessory
                val accessories = usbManager?.accessoryList
                if (!accessories.isNullOrEmpty()) {
                    handleAccessoryAttached(accessories[0])
                } else {
                    // No accessory found, start polling
                    startAccessoryPolling()
                }
            }
        }, delayMs)
    }

    /**
     * Reset auto-reconnect state (called on successful connection)
     */
    private fun resetAutoReconnect() {
        autoReconnectAttempts = 0
    }

    /**
     * Request permission for the current accessory
     */
    private fun requestPermission(result: MethodChannel.Result) {
        val currentAccessory = accessory
        if (currentAccessory == null) {
            // Try to find an available accessory
            val accessories = usbManager?.accessoryList
            if (accessories.isNullOrEmpty()) {
                result.error("NO_ACCESSORY", "No USB accessory connected", null)
                return
            }
            accessory = accessories[0]
        }

        if (usbManager?.hasPermission(accessory!!) == true) {
            result.success(true)
            return
        }

        requestPermissionForAccessory(accessory!!)
        // Result will be delivered via broadcast receiver
        result.success(null) // Pending
    }

    /**
     * Request permission for a specific accessory
     */
    private fun requestPermissionForAccessory(accessory: UsbAccessory) {
        // Create explicit intent with package to satisfy Android 14+ requirements
        val intent = Intent(ACTION_USB_PERMISSION).apply {
            setPackage(context.packageName)
        }

        // Android 12+ (S): Must specify mutability flag
        // Android 14+ (U): FLAG_MUTABLE requires explicit intent, but USB permission
        // broadcasts work with FLAG_IMMUTABLE since we don't need to modify the intent
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val permissionIntent = PendingIntent.getBroadcast(context, 0, intent, flags)
        usbManager?.requestPermission(accessory, permissionIntent)
        Log.d(TAG, "Requested USB permission for accessory")
    }

    /**
     * Register receiver for permission responses
     */
    private fun registerPermissionReceiver() {
        permissionReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == ACTION_USB_PERMISSION) {
                    val accessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                    }

                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)

                    if (granted && accessory != null) {
                        Log.d(TAG, "USB permission granted")
                        this@UsbAoaPlugin.accessory = accessory
                        safeExecute {
                            val success = openAccessoryInternal()
                            mainHandler.post {
                                if (success) {
                                    notifyConnected(accessory)
                                }
                            }
                        }
                    } else {
                        Log.d(TAG, "USB permission denied")
                        mainHandler.post {
                            methodChannel?.invokeMethod("onError", mapOf(
                                "error" to "USB permission denied"
                            ))
                        }
                    }
                }
            }
        }

        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(permissionReceiver, filter)
        }
    }

    /**
     * Register receiver for accessory detach events
     */
    private fun registerDetachReceiver() {
        detachReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                try {
                    if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_DETACHED) {
                        val detachedAccessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                        }

                        // Compare by manufacturer/model instead of equals() which requires permission
                        val currentAccessory = accessory
                        if (detachedAccessory != null && currentAccessory != null &&
                            detachedAccessory.manufacturer == currentAccessory.manufacturer &&
                            detachedAccessory.model == currentAccessory.model) {
                            Log.d(TAG, "USB accessory detached")
                            safeExecute {
                                closeInternal()
                                mainHandler.post {
                                    notifyDisconnected()
                                }
                            }
                            accessory = null
                        } else if (detachedAccessory != null) {
                            // Any accessory detached while we're connected - close for safety
                            Log.d(TAG, "USB accessory detached (different or unknown)")
                            if (isConnected.get()) {
                                safeExecute {
                                    closeInternal()
                                    mainHandler.post {
                                        notifyDisconnected()
                                    }
                                }
                                accessory = null
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error in detach receiver: ${e.message}", e)
                }
            }
        }

        val filter = IntentFilter(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(detachReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(detachReceiver, filter)
        }
    }

    /**
     * Register receiver for USB accessory attached events
     * This complements the manifest intent-filter to ensure we catch connections
     */
    private fun registerAttachReceiver() {
        attachReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
                    val attachedAccessory = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                    }

                    if (attachedAccessory != null) {
                        Log.d(TAG, "USB accessory attached (broadcast): ${attachedAccessory.manufacturer} ${attachedAccessory.model}")
                        handleAccessoryAttached(attachedAccessory)
                    }
                }
            }
        }

        val filter = IntentFilter(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(attachReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(attachReceiver, filter)
        }
    }

    /**
     * Check if there's already an accessory connected when the plugin initializes
     */
    private fun checkForExistingAccessory() {
        Log.d(TAG, "checkForExistingAccessory() called, usbManager=${usbManager != null}")
        val accessories = usbManager?.accessoryList
        Log.d(TAG, "accessoryList: ${accessories?.size ?: "null"} accessories")
        if (!accessories.isNullOrEmpty()) {
            val existingAccessory = accessories[0]
            Log.d(TAG, "Found existing accessory at startup: ${existingAccessory.manufacturer} ${existingAccessory.model}")
            handleAccessoryAttached(existingAccessory)
        } else {
            Log.d(TAG, "No existing accessory found at startup, starting polling...")
            startAccessoryPolling()
        }
    }

    private var pollingHandler: Handler? = null
    private var pollingRunnable: Runnable? = null
    private val isPolling = AtomicBoolean(false)

    /**
     * Start polling for USB accessories (for Android 15+ where broadcasts are unreliable)
     */
    private fun startAccessoryPolling() {
        if (isPolling.getAndSet(true)) {
            Log.d(TAG, "startAccessoryPolling: already polling")
            return
        }

        Log.d(TAG, "startAccessoryPolling: starting 500ms poll loop")
        pollingHandler = Handler(Looper.getMainLooper())
        pollingRunnable = object : Runnable {
            var pollCount = 0
            override fun run() {
                pollCount++
                if (!isPolling.get() || isConnected.get()) {
                    Log.d(TAG, "Polling stopped: isPolling=${isPolling.get()}, isConnected=${isConnected.get()}")
                    stopAccessoryPolling()
                    return
                }

                val accessories = usbManager?.accessoryList
                Log.d(TAG, "Poll #$pollCount: accessoryList has ${accessories?.size ?: 0} items")
                if (!accessories.isNullOrEmpty()) {
                    val foundAccessory = accessories[0]
                    Log.d(TAG, "Polling found accessory: ${foundAccessory.manufacturer} ${foundAccessory.model}")
                    stopAccessoryPolling()
                    handleAccessoryAttached(foundAccessory)
                } else {
                    // Poll again in 500ms (faster detection)
                    pollingHandler?.postDelayed(this, 500)
                }
            }
        }

        // Start polling immediately
        pollingHandler?.post(pollingRunnable!!)
    }

    /**
     * Stop polling for accessories
     */
    private fun stopAccessoryPolling() {
        isPolling.set(false)
        pollingRunnable?.let { pollingHandler?.removeCallbacks(it) }
        pollingHandler = null
        pollingRunnable = null
    }

    /**
     * Unregister broadcast receivers
     */
    private fun unregisterReceivers() {
        permissionReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Receiver not registered
            }
        }
        permissionReceiver = null

        detachReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Receiver not registered
            }
        }
        detachReceiver = null

        attachReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
                // Receiver not registered
            }
        }
        attachReceiver = null
    }

    /**
     * Safely get the serial number from an accessory.
     * Returns null if the user hasn't granted USB permission (SecurityException).
     */
    private fun safeGetSerial(accessory: UsbAccessory): String? {
        return try {
            accessory.serial
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot read accessory serial (no permission): ${e.message}")
            null
        }
    }

    /**
     * Notify Dart of successful connection
     */
    private fun notifyConnected(accessory: UsbAccessory) {
        if (isDisposed.get()) {
            Log.w(TAG, "notifyConnected ignored - plugin disposed")
            return
        }
        methodChannel?.invokeMethod("onAccessoryConnected", mapOf(
            "manufacturer" to accessory.manufacturer,
            "model" to accessory.model,
            "description" to accessory.description,
            "version" to accessory.version,
            "uri" to accessory.uri,
            "serial" to safeGetSerial(accessory)
        ))
    }

    /**
     * Notify Dart of disconnection
     */
    private fun notifyDisconnected() {
        if (isDisposed.get()) {
            Log.w(TAG, "notifyDisconnected ignored - plugin disposed")
            return
        }
        methodChannel?.invokeMethod("onAccessoryDisconnected", null)
    }

    /**
     * Notify Dart of received data
     */
    private fun notifyDataReceived(data: ByteArray) {
        if (isDisposed.get()) {
            Log.w(TAG, "notifyDataReceived ignored - plugin disposed")
            return
        }
        Log.d(TAG, "Received ${data.size} bytes, forwarding to Dart")
        methodChannel?.invokeMethod("onDataReceived", mapOf(
            "data" to data
        ))
    }
}
