import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';

import 'brain.dart' show wavFromPcm16;

/// Plays Tommy's voice as it arrives (raw 16-bit PCM pieces from Gemini Live), so speech starts
/// within a fraction of a second instead of waiting for the whole answer.
/// If the streaming engine can't start on a device, it falls back to playing each answer as one WAV.
class PcmSpeaker {
  final int rate;
  PcmSpeaker({this.rate = 24000});

  bool _ready = false;
  bool _broken = false;
  AudioSource? _src;
  SoundHandle? _handle;
  DateTime _endsAt = DateTime.fromMillisecondsSinceEpoch(0);

  // fallback
  final _fallback = AudioPlayer();
  final _pending = BytesBuilder(copy: false);

  /// True while sound is (or should still be) coming out of the speaker.
  bool get speaking => DateTime.now().isBefore(_endsAt);
  DateTime get endsAt => _endsAt;

  /// Starts the sound engine early so the first answer isn't delayed.
  Future<void> warmUp() => _init();

  Future<void> _init() async {
    if (_ready || _broken) return;
    try {
      await SoLoud.instance.init(channels: Channels.mono);
      _ready = true;
    } catch (_) {
      _broken = true;
    }
  }

  /// Adds one piece of PCM16 mono audio.
  Future<void> add(Uint8List pcm) async {
    if (pcm.isEmpty) return;
    await _init();
    final now = DateTime.now();
    final dur = Duration(microseconds: pcm.length * 1000000 ~/ (rate * 2));
    _endsAt = (_endsAt.isAfter(now) ? _endsAt : now.add(const Duration(milliseconds: 120))).add(dur);
    if (_broken) {
      _pending.add(pcm);
      return;
    }
    try {
      if (_src == null) {
        _src = SoLoud.instance.setBufferStream(
          maxBufferSizeDuration: const Duration(minutes: 5),
          bufferingType: BufferingType.released,
          bufferingTimeNeeds: 0.12,
          sampleRate: rate,
          channels: Channels.mono,
          format: BufferType.s16le,
        );
        SoLoud.instance.addAudioDataStream(_src!, pcm);
        _handle = SoLoud.instance.play(_src!);
      } else {
        SoLoud.instance.addAudioDataStream(_src!, pcm);
      }
    } catch (_) {
      _broken = true;
      _pending.add(pcm);
    }
  }

  /// The answer is complete (the stream can end once played).
  Future<void> finish() async {
    if (_broken) {
      final bytes = _pending.takeBytes();
      if (bytes.isEmpty) return;
      final d = await getTemporaryDirectory();
      final path = '${d.path}${Platform.pathSeparator}tommy_live.wav';
      await File(path).writeAsBytes(wavFromPcm16(bytes, rate), flush: true);
      _endsAt = DateTime.now().add(Duration(microseconds: bytes.length * 1000000 ~/ (rate * 2)) + const Duration(milliseconds: 300));
      await _fallback.play(DeviceFileSource(path));
      return;
    }
    final s = _src;
    _src = null;
    _handle = null;
    if (s != null) {
      try {
        SoLoud.instance.setDataIsEnded(s);
      } catch (_) {}
      // free it a little after it has finished playing
      final wait = _endsAt.difference(DateTime.now()) + const Duration(seconds: 2);
      Timer(wait.isNegative ? const Duration(seconds: 2) : wait, () async {
        try {
          await SoLoud.instance.disposeSource(s);
        } catch (_) {}
      });
    }
  }

  /// Stop talking right now (the person interrupted, or said "stop").
  Future<void> stop() async {
    _endsAt = DateTime.fromMillisecondsSinceEpoch(0);
    _pending.clear();
    try {
      await _fallback.stop();
    } catch (_) {}
    final s = _src;
    final h = _handle;
    _src = null;
    _handle = null;
    if (!_ready) return;
    try {
      if (h != null) await SoLoud.instance.stop(h);
    } catch (_) {}
    try {
      if (s != null) await SoLoud.instance.disposeSource(s);
    } catch (_) {}
  }
}
