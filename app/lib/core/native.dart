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

  // ---- Tommy's hands (accessibility service) ----
  static Future<bool> handsOn() async => (await _call<bool>('handsOn')) ?? false;
  static Future<void> openHandsSettings() => _call('openHandsSettings');
  static Future<Map<String, dynamic>?> screen() async {
    final r = await _call<Map>('screen');
    return r == null ? null : Map<String, dynamic>.from(r);
  }

  static Future<bool> tap(String target) async => (await _call<bool>('tap', {'target': target})) ?? false;
  static Future<bool> typeText(String text) async => (await _call<bool>('typeText', {'text': text})) ?? false;
  static Future<bool> press(String key) async => (await _call<bool>('press', {'key': key})) ?? false;
  static Future<bool> scroll(String direction) async => (await _call<bool>('scroll', {'direction': direction})) ?? false;
  static Future<bool> armAutoSend() async => (await _call<bool>('armAutoSend')) ?? false;

  // ---- contacts & calls ----
  static Future<Map<String, String>?> findContact(String name) async {
    final r = await _call<Map>('findContact', {'name': name});
    return r == null ? null : r.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// 'calling' | 'dialer' | 'no_number' | null (not Android)
  static Future<String?> callNumber(String number) => _call<String>('callNumber', {'number': number});

  static Future<bool> media(String action) async => (await _call<bool>('media', {'action': action})) ?? false;
  static Future<bool> closeApp(String name) async => (await _call<bool>('closeApp', {'name': name})) ?? false;
}
