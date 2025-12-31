package dev.geogram;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

/**
 * Foreground service to keep downloads running when the app goes to background.
 * Android aggressively throttles background network operations to save battery.
 * This service keeps the download active with a persistent notification and wake lock.
 */
public class DownloadForegroundService extends Service {

    private static final String TAG = "DownloadForegroundSvc";
    private static final String CHANNEL_ID = "geogram_download_channel";
    private static final int NOTIFICATION_ID = 1002;

    private PowerManager.WakeLock wakeLock;
    private int downloadProgress = 0;
    private String downloadStatus = "Downloading update...";

    public static void start(Context context) {
        Intent intent = new Intent(context, DownloadForegroundService.class);
        intent.setAction("START");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
        Log.d(TAG, "Download foreground service start requested");
    }

    public static void stop(Context context) {
        Intent intent = new Intent(context, DownloadForegroundService.class);
        context.stopService(intent);
        Log.d(TAG, "Download foreground service stop requested");
    }

    public static void updateProgress(Context context, int progress, String status) {
        Intent intent = new Intent(context, DownloadForegroundService.class);
        intent.setAction("UPDATE_PROGRESS");
        intent.putExtra("progress", progress);
        intent.putExtra("status", status);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.d(TAG, "Download foreground service created");
        createNotificationChannel();
        acquireWakeLock();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        Log.d(TAG, "Download foreground service onStartCommand, action=" + action);

        if ("UPDATE_PROGRESS".equals(action)) {
            downloadProgress = intent.getIntExtra("progress", 0);
            downloadStatus = intent.getStringExtra("status");
            if (downloadStatus == null) {
                downloadStatus = "Downloading update...";
            }
            updateNotification();
        } else {
            // START action or null - start the service
            Notification notification = createNotification();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        }

        // Keep the service running
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        Log.d(TAG, "Download foreground service destroyed");
        releaseWakeLock();
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void updateNotification() {
        NotificationManager notificationManager = getSystemService(NotificationManager.class);
        if (notificationManager != null) {
            notificationManager.notify(NOTIFICATION_ID, createNotification());
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Downloads",
                    NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Downloading updates");
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

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Geogram Update")
                .setContentText(downloadStatus)
                .setSmallIcon(R.drawable.ic_notification)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_LOW);

        // Show progress bar if we have progress info
        if (downloadProgress > 0 && downloadProgress < 100) {
            builder.setProgress(100, downloadProgress, false);
        } else if (downloadProgress == 0) {
            // Indeterminate progress when we don't have progress yet
            builder.setProgress(0, 0, true);
        }

        return builder.build();
    }

    private void acquireWakeLock() {
        PowerManager powerManager = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (powerManager != null) {
            wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Geogram::DownloadWakeLock"
            );
            // Acquire with a 30-minute timeout as a safety net
            wakeLock.acquire(30 * 60 * 1000L);
            Log.d(TAG, "Download wake lock acquired");
        }
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
            Log.d(TAG, "Download wake lock released");
        }
        wakeLock = null;
    }
}
