package com.tommyai.tommy

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Tommy's "hands": an accessibility service (the person turns it on once in Settings → Accessibility).
 * It lets Tommy read what is on the screen and press buttons / type, so tasks can be finished
 * (e.g. pressing WhatsApp's Send button) instead of stopping halfway.
 */
class HandsService : AccessibilityService() {
    companion object {
        @Volatile var instance: HandsService? = null
        @Volatile var autoSendUntil: Long = 0L // press WhatsApp "Send" once if it appears before this time
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (autoSendUntil == 0L) return
        if (System.currentTimeMillis() > autoSendUntil) { autoSendUntil = 0L; return }
        val pkg = event?.packageName?.toString() ?: return
        if (!pkg.startsWith("com.whatsapp")) return
        val root = rootInActiveWindow ?: return
        val btn = root.findAccessibilityNodeInfosByViewId("$pkg:id/send").firstOrNull()
            ?: findNode(root) { n ->
                val d = n.contentDescription?.toString()?.lowercase() ?: ""
                n.isClickable && (d == "send" || d == "পাঠান" || d == "भेजें")
            }
        if (btn != null && btn.isEnabled) {
            autoSendUntil = 0L
            Handler(Looper.getMainLooper()).postDelayed({ btn.performAction(AccessibilityNodeInfo.ACTION_CLICK) }, 400)
        }
    }

    private fun findNode(root: AccessibilityNodeInfo, test: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var seen = 0
        while (queue.isNotEmpty() && seen < 2000) {
            val n = queue.removeFirst()
            seen++
            if (test(n)) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { queue.add(it) }
        }
        return null
    }

    private fun label(n: AccessibilityNodeInfo): String {
        val t = n.text?.toString()?.trim().orEmpty()
        val d = n.contentDescription?.toString()?.trim().orEmpty()
        return if (t.isNotEmpty()) t else d
    }

    /** Visible texts and buttons on the screen, top to bottom (max ~120 lines). */
    fun screen(): Map<String, Any> {
        val root = rootInActiveWindow ?: return mapOf("app" to "", "items" to emptyList<String>())
        val items = mutableListOf<String>()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var seen = 0
        while (queue.isNotEmpty() && seen < 2500 && items.size < 120) {
            val n = queue.removeFirst()
            seen++
            if (n.isVisibleToUser) {
                val l = label(n)
                if (l.isNotEmpty()) {
                    val kind = when {
                        n.isEditable -> "[input] "
                        n.isClickable -> "[button] "
                        else -> ""
                    }
                    items.add(kind + l.take(80))
                } else if (n.isEditable) {
                    items.add("[input] (empty)")
                }
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { queue.add(it) }
        }
        return mapOf("app" to (root.packageName?.toString() ?: ""), "items" to items.distinct())
    }

    /** Presses the button/item whose text best matches [target]. */
    fun tap(target: String): Boolean {
        val want = target.trim().lowercase()
        if (want.isEmpty()) return false
        val root = rootInActiveWindow ?: return false
        val exact = findNode(root) { it.isVisibleToUser && label(it).lowercase() == want }
        val node = exact ?: findNode(root) { it.isVisibleToUser && label(it).lowercase().contains(want) } ?: return false
        var n: AccessibilityNodeInfo? = node
        while (n != null && !n.isClickable) n = n.parent
        return (n ?: node).performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** Types into the focused input box (or the first one on screen). */
    fun typeText(text: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val box = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }
            ?: findNode(root) { it.isEditable && it.isVisibleToUser } ?: return false
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return box.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun press(key: String): Boolean = when (key.lowercase()) {
        "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
        "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
        "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        else -> false
    }

    fun scroll(direction: String): Boolean {
        val root = rootInActiveWindow ?: return false
        val node = findNode(root) { it.isScrollable && it.isVisibleToUser } ?: return false
        val action = if (direction.lowercase() == "up") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        return node.performAction(action)
    }
}
