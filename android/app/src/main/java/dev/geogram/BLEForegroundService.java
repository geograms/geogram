package dev.geogram;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

import io.flutter.plugin.common.MethodChannel;

/**
 * Foreground service to keep BLE and WebSocket connections active when app goes to background.
 * Android aggressively throttles background operations to save battery.
 * This service keeps the app alive with a persistent notification and handles:
 * 1. BLE GATT server operations
 * 2. WebSocket keep-alive pings to the internet station (p2p.radio)
 *
 * The WebSocket keep-alive is critical because Android devices are servers that need
 * to be reachable by outside visitors even when the display is off.
 */
public class BLEForegroundService extends Service {

    private static final String TAG = "BLEForegroundService";
    private static final String CHANNEL_ID = "geogram_ble_channel";
    private static final int NOTIFICATION_ID = 1001;

    // WebSocket keep-alive interval (55 seconds - slightly less than the 60s Dart timer
    // to ensure we always beat the server's idle timeout)
    private static final long KEEPALIVE_INTERVAL_MS = 55 * 1000;

    private PowerManager.WakeLock wakeLock;
    private Handler keepAliveHandler;
    private Runnable keepAliveRunnable;
    private boolean keepAliveEnabled = false;

    // Static reference to method channel for callbacks to Flutter
    private static MethodChannel methodChannel;

    public static void setMethodChannel(MethodChannel channel) {
        methodChannel = channel;
    }

    public static void start(Context context) {
        Intent intent = new Intent(context, BLEForegroundService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
        Log.d(TAG, "Foreground service start requested");
    }

    public static void stop(Context context) {
        Intent intent = new Intent(context, BLEForegroundService.class);
        context.stopService(intent);
        Log.d(TAG, "Foreground service stop requested");
    }

    /**
     * Enable WebSocket keep-alive from the foreground service.
     * This should be called after WebSocket connects to the station.
     */
    public static void enableKeepAlive(Context context) {
        Intent intent = new Intent(context, BLEForegroundService.class);
        intent.setAction("ENABLE_KEEPALIVE");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
        Log.d(TAG, "WebSocket keep-alive enable requested");
    }

    /**
     * Disable WebSocket keep-alive (called when WebSocket disconnects).
     */
    public static void disableKeepAlive(Context context) {
        Intent intent = new Intent(context, BLEForegroundService.class);
        intent.setAction("DISABLE_KEEPALIVE");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
        Log.d(TAG, "WebSocket keep-alive disable requested");
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "Foreground service created");
        createNotificationChannel();
        acquireWakeLock();

        // Initialize keep-alive handler on main looper
        keepAliveHandler = new Handler(Looper.getMainLooper());
        keepAliveRunnable = new Runnable() {
            @Override
            public void run() {
                if (keepAliveEnabled) {
                    sendKeepAlivePing();
                    // Schedule next ping
                    keepAliveHandler.postDelayed(this, KEEPALIVE_INTERVAL_MS);
                }
            }
        };
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        Log.d(TAG, "Foreground service onStartCommand, action=" + action);

        Notification notification = createNotification();

        // Use both connectedDevice (for BLE) and dataSync (for WebSocket/network) service types
        // This ensures network operations continue even when the display is off
        // Note: On Android 14+ (API 34+), CONNECTED_DEVICE type requires Bluetooth permissions
        // to be granted at runtime, not just declared in the manifest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            int serviceType;
            if (hasBluetoothPermissions()) {
                // Full service with BLE support
                serviceType = android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE |
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC;
                Log.d(TAG, "Starting foreground service with CONNECTED_DEVICE|DATA_SYNC types");
            } else {
                // Fallback to dataSync only when Bluetooth permissions not granted
                serviceType = android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC;
                Log.w(TAG, "Bluetooth permissions not granted, using DATA_SYNC type only");
            }
            startForeground(NOTIFICATION_ID, notification, serviceType);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        // Handle keep-alive enable/disable actions
        if ("ENABLE_KEEPALIVE".equals(action)) {
            startKeepAlive();
        } else if ("DISABLE_KEEPALIVE".equals(action)) {
            stopKeepAlive();
        }

        // Keep the service running
        return START_STICKY;
    }

    /**
     * Check if any of the Bluetooth permissions required for FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
     * are granted. On Android 12+ (API 31+), we need BLUETOOTH_CONNECT, BLUETOOTH_SCAN, or BLUETOOTH_ADVERTISE.
     * On older versions, the legacy BLUETOOTH permission is sufficient.
     */
    private boolean hasBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ requires new Bluetooth permissions
            return ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED ||
                   ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED ||
                   ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED;
        } else {
            // Pre-Android 12 uses legacy BLUETOOTH permission (normal permission, auto-granted)
            return ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED;
        }
    }

    @Override
    public void onDestroy() {
        Log.d(TAG, "Foreground service destroyed");
        stopKeepAlive();
        releaseWakeLock();
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void startKeepAlive() {
        if (!keepAliveEnabled) {
            keepAliveEnabled = true;
            Log.d(TAG, "WebSocket keep-alive started (interval=" + KEEPALIVE_INTERVAL_MS + "ms)");
            // Start the first ping after the interval
            keepAliveHandler.postDelayed(keepAliveRunnable, KEEPALIVE_INTERVAL_MS);
            // Update notification to reflect connected state
            updateNotification();
        }
    }

    private void stopKeepAlive() {
        if (keepAliveEnabled) {
            keepAliveEnabled = false;
            keepAliveHandler.removeCallbacks(keepAliveRunnable);
            Log.d(TAG, "WebSocket keep-alive stopped");
            // Update notification to reflect disconnected state
            updateNotification();
        }
    }

    /**
     * Update the notification to reflect the current keep-alive state.
     */
    private void updateNotification() {
        NotificationManager notificationManager = getSystemService(NotificationManager.class);
        if (notificationManager != null) {
            notificationManager.notify(NOTIFICATION_ID, createNotification());
        }
    }

    /**
     * Send keep-alive ping by invoking the Dart callback via MethodChannel.
     * This runs on the main thread which is required for MethodChannel calls.
     */
    private void sendKeepAlivePing() {
        if (methodChannel != null) {
            Log.d(TAG, "Sending WebSocket keep-alive ping via MethodChannel");
            methodChannel.invokeMethod("onKeepAlivePing", null);
        } else {
            Log.w(TAG, "MethodChannel not set, cannot send keep-alive ping");
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Network",
                    NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Keeping connections active");
            channel.setShowBadge(false);

            NotificationManager notificationManager = getSystemService(NotificationManager.class);
            if (notificationManager != null) {
                notificationManager.createNotificationChannel(channel);
            }
        }
    }

    private Notification createNotification() {
        // Intent to open the app when notification is tapped
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, flags);

        String contentText = keepAliveEnabled ? "Connected to station" : "BLE active";

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Geogram")
                .setContentText(contentText)
                .setSmallIcon(R.drawable.ic_notification)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
    }

    private void acquireWakeLock() {
        PowerManager powerManager = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (powerManager != null) {
            wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Geogram::NetworkWakeLock"
            );
            // Acquire indefinitely while service runs (released in onDestroy)
            wakeLock.acquire();
            Log.d(TAG, "Wake lock acquired");
        }
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
            Log.d(TAG, "Wake lock released");
        }
        wakeLock = null;
    }
}
