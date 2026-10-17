package com.tommyai.tommy

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/** Reads new notifications (messages, incoming calls) so Tommy can announce them. Needs "Notification access". */
class NotifyListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification ?: return
        val extras = n.extras ?: return
        val isCall = n.category == Notification.CATEGORY_CALL
        if (!isCall) {
            if (sbn.isOngoing) return
            if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
            val cat = n.category
            if (cat != null && cat != Notification.CATEGORY_MESSAGE && cat != Notification.CATEGORY_EMAIL &&
                cat != Notification.CATEGORY_SOCIAL) return
        }
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (e: Exception) { sbn.packageName }
        EventHub.send(mapOf(
            "type" to (if (isCall) "call" else "message"),
            "app" to app, "package" to sbn.packageName, "title" to title, "text" to text
        ))
    }
}
