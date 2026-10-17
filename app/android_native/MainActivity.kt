package com.tommyai.tommy

import android.Manifest
import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "tommy/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { EventHub.sink = events }
            override fun onCancel(arguments: Any?) { EventHub.sink = null }
        })

        MethodChannel(messenger, "tommy/native").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startKeepAlive" -> {
                        val i = Intent(this, KeepAliveService::class.java)
                            .putExtra("title", call.argument<String>("title") ?: "Tommy")
                            .putExtra("text", call.argument<String>("text") ?: "Listening")
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                        result.success(true)
                    }
                    "stopKeepAlive" -> { stopService(Intent(this, KeepAliveService::class.java)); result.success(true) }
                    "requestPermissions" -> { askPermissions(); result.success(true) }
                    "notificationAccess" -> result.success(hasNotificationAccess())
                    "openNotificationSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                    "answerCall" -> result.success(answerCall())
                    "endCall" -> result.success(endCall())
                    "openApp" -> result.success(openApp(call.argument<String>("name") ?: ""))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("ERR", e.message, null)
            }
        }
    }

    private fun askPermissions() {
        if (Build.VERSION.SDK_INT < 23) return
        val wanted = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 26) wanted.add(Manifest.permission.ANSWER_PHONE_CALLS)
        if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        val missing = wanted.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 42)
    }

    private fun hasNotificationAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(this, NotifyListener::class.java).flattenToString()
        return flat.split(":").any { it == me }
    }

    @SuppressLint("MissingPermission")
    private fun answerCall(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        if (checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED) return false
        val tm = getSystemService(TELECOM_SERVICE) as TelecomManager
        tm.acceptRingingCall()
        return true
    }

    @SuppressLint("MissingPermission")
    private fun endCall(): Boolean {
        if (Build.VERSION.SDK_INT < 28) return false
        if (checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) != PackageManager.PERMISSION_GRANTED) return false
        val tm = getSystemService(TELECOM_SERVICE) as TelecomManager
        return tm.endCall()
    }

    /** Finds an installed app by its visible name ("WhatsApp", "Camera"…) and opens it. */
    private fun openApp(name: String): Boolean {
        val want = name.trim().lowercase()
        if (want.isEmpty()) return false
        val pm = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = pm.queryIntentActivities(launcher, 0)
        val match = apps.firstOrNull { it.loadLabel(pm).toString().lowercase() == want }
            ?: apps.firstOrNull { it.loadLabel(pm).toString().lowercase().contains(want) }
            ?: apps.firstOrNull { want.contains(it.loadLabel(pm).toString().lowercase()) }
            ?: return false
        val intent = pm.getLaunchIntentForPackage(match.activityInfo.packageName) ?: return false
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }
}
