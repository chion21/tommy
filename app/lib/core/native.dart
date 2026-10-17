import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Android-only extras (keep listening in background, calls & notifications, opening apps).
/// On Windows these quietly do nothing.
class Native {
  static const _m = MethodChannel('tommy/native');
  static const _e = EventChannel('tommy/events');
  static bool get android => Platform.isAndroid;

  static Stream<Map<String, dynamic>> events() => android
      ? _e.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map))
      : const Stream.empty();

  static Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!android) return null;
    try {
      return await _m.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  static Future<void> startKeepAlive(String title, String text) => _call('startKeepAlive', {'title': title, 'text': text});
  static Future<void> stopKeepAlive() => _call('stopKeepAlive');
  static Future<void> requestPermissions() => _call('requestPermissions');
  static Future<bool> notificationAccess() async => (await _call<bool>('notificationAccess')) ?? false;
  static Future<void> openNotificationSettings() => _call('openNotificationSettings');
  static Future<bool> answerCall() async => (await _call<bool>('answerCall')) ?? false;
  static Future<bool> endCall() async => (await _call<bool>('endCall')) ?? false;
  static Future<bool> openApp(String name) async => (await _call<bool>('openApp', {'name': name})) ?? false;
}
