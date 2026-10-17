import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Microphone + speaker. Records one utterance at a time and decides by loudness when speech starts and ends
/// (works the same on Android and Windows). Plays replies (WAV bytes) or falls back to the device voice.
class VoiceIO {
  final _rec = AudioRecorder();
  final _player = AudioPlayer();
  final _tts = FlutterTts();
  StreamSubscription<Amplitude>? _ampSub;
  bool _recording = false;
  bool _stopNow = false;
  int _n = 0;

  /// Live loudness 0..1 for the waveform.
  final level = StreamController<double>.broadcast();

  Future<bool> hasMicPermission() => _rec.hasPermission();

  Future<String> _tmp(String ext) async {
    final d = await getTemporaryDirectory();
    _n = (_n + 1) % 4;
    return '${d.path}${Platform.pathSeparator}tommy_$_n.$ext';
  }

  /// Waits for speech, records it, and returns the WAV bytes — or null if nothing was said in [waitFor]
  /// or [cancel] was called. [maxTalk] limits one utterance.
  Future<Uint8List?> listenOnce({
    Duration waitFor = const Duration(seconds: 8),
    Duration maxTalk = const Duration(seconds: 15),
    Duration endSilence = const Duration(milliseconds: 1100),
  }) async {
    if (_recording) return null;
    if (!await _rec.hasPermission()) throw Exception('MIC_DENIED');
    final path = await _tmp('wav');
    _stopNow = false;
    _recording = true;
    await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);

    final started = DateTime.now();
    DateTime? speechStart;
    DateTime lastLoud = DateTime.now();
    DateTime? lastAmp;
    double noise = -50; // running noise floor in dBFS
    final done = Completer<bool>(); // true = got speech

    _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
      final now = DateTime.now();
      lastAmp = now;
      final db = a.current.isFinite ? a.current : -100.0;
      level.add(((db + 60) / 60).clamp(0.0, 1.0));
      final threshold = (noise + 14).clamp(-48.0, -18.0);
      if (db > threshold) {
        speechStart ??= now;
        lastLoud = now;
      } else if (speechStart == null) {
        noise = noise * 0.9 + db * 0.1; // learn the room's background noise while waiting
      }
    });

    // Decide every 100 ms. If this device gives no loudness readings, record a fixed 6 s instead.
    final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (done.isCompleted) return;
      final now = DateTime.now();
      final blind = lastAmp == null && now.difference(started) > const Duration(milliseconds: 1500);
      if (_stopNow) {
        done.complete(false);
      } else if (blind && now.difference(started) > const Duration(seconds: 6)) {
        done.complete(true);
      } else if (!blind && speechStart == null && now.difference(started) > waitFor) {
        done.complete(false);
      } else if (speechStart != null &&
          (now.difference(lastLoud) > endSilence || now.difference(speechStart!) > maxTalk)) {
        done.complete(now.difference(speechStart!) > const Duration(milliseconds: 350));
      }
    });

    final got = await done.future;
    ticker.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    final out = await _rec.stop();
    _recording = false;
    level.add(0);
    if (!got || out == null) return null;
    final f = File(out);
    return await f.exists() ? await f.readAsBytes() : null;
  }

  void cancel() => _stopNow = true;
  bool get isRecording => _recording;

  /// Plays WAV bytes and waits until finished.
  Future<void> playWav(Uint8List wav) async {
    final path = await _tmp('reply.wav');
    await File(path).writeAsBytes(wav, flush: true);
    final finished = _player.onPlayerComplete.first;
    await _player.play(DeviceFileSource(path));
    level.add(0.6);
    await finished.timeout(const Duration(minutes: 2), onTimeout: () {});
    level.add(0);
  }

  /// Device text-to-speech fallback (Android: Google voice incl. Bangla; Windows: system voices).
  Future<void> speakDevice(String text, String lang) async {
    final code = switch (lang) { 'en' => 'en-US', 'hi' => 'hi-IN', _ => 'bn-BD' };
    try {
      await _tts.setLanguage(code);
    } catch (_) {}
    await _tts.awaitSpeakCompletion(true);
    level.add(0.6);
    await _tts.speak(text);
    level.add(0);
  }

  Future<void> stopSpeaking() async {
    await _player.stop();
    await _tts.stop();
  }

  Future<void> dispose() async {
    await _ampSub?.cancel();
    await _rec.dispose();
    await _player.dispose();
  }
}
