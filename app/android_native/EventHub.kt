package com.tommyai.tommy

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Passes call/message events from the notification listener to the Flutter app. */
object EventHub {
    @Volatile var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    fun send(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }
}
