import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_data.dart';

/// Pairing data shared by QR code: a random channel id + a secret key. Messages travel through a free public
/// MQTT relay, but are end-to-end encrypted (AES-GCM) — the relay cannot read or fake them.
class Pairing {
  final String id; // 32 hex chars
  final String key; // base64 32 bytes
  final String peerName;
  const Pairing(this.id, this.key, this.peerName);

  static Pairing create() {
    final r = Random.secure();
    final id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final key = base64Encode(List.generate(32, (_) => r.nextInt(256)));
    return Pairing(id, key, '');
  }

  String qr(String myName) => jsonEncode({'t': 'tommy-pair', 'v': 1, 'id': id, 'k': key, 'n': myName});

  static Pairing? fromQr(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['t'] != 'tommy-pair') return null;
      return Pairing(j['id'] as String, j['k'] as String, (j['n'] ?? '') as String);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {'id': id, 'key': key, 'peer': peerName};
  static Pairing? fromJson(Map<String, dynamic>? j) =>
      j == null || j['id'] == null ? null : Pairing(j['id'] as String, j['key'] as String, (j['peer'] ?? '') as String);
  Pairing withPeer(String name) => Pairing(id, key, name);
}

/// Keeps the PC and phone in touch: heartbeats (online/offline light) and commands ("open YouTube on the PC").
class DeviceLink {
  static const _brokers = [('broker.hivemq.com', 8883), ('broker.emqx.io', 8883), ('test.mosquitto.org', 8886)];
  static const _beat = Duration(seconds: 10);
  static const _onlineWindow = Duration(seconds: 32);

  final String me; // 'pc' | 'phone'
  final String myName;
  final Pairing pairing;
  final void Function() onChange;
  final void Function(Map<String, dynamic> msg) onMessage;

  MqttServerClient? _client;
  Timer? _hb;
  Timer? _watch;
  DateTime? _lastSeen;
  String peerName;
  bool connected = false;
  bool _closing = false;
  final _algo = AesGcm.with256bits();
  late final SecretKey _key = SecretKey(base64Decode(pairing.key));

  DeviceLink({required this.me, required this.myName, required this.pairing, required this.onChange, required this.onMessage})
      : peerName = pairing.peerName;

  String get peer => me == 'pc' ? 'phone' : 'pc';
  String get _myTopic => 'tommy/${pairing.id}/$me';
  String get _peerTopic => 'tommy/${pairing.id}/$peer';
  bool get peerOnline => _lastSeen != null && DateTime.now().difference(_lastSeen!) < _onlineWindow;

  Future<void> start() async {
    _closing = false;
    await _connect();
    _hb = Timer.periodic(_beat, (_) => _send({'type': 'hb'}));
    _watch = Timer.periodic(const Duration(seconds: 5), (_) => onChange()); // refresh the light
  }

  Future<void> _connect() async {
    for (final (host, port) in _brokers) {
      if (_closing) return;
      final id = 'tommy_${me}_${Random().nextInt(1 << 31)}';
      final c = MqttServerClient.withPort(host, id, port)
        ..secure = true
        ..keepAlivePeriod = 30
        ..connectTimeoutPeriod = 8000
        ..autoReconnect = true
        ..resubscribeOnAutoReconnect = true
        ..logging(on: false);
      c.setProtocolV311();
      c.connectionMessage = MqttConnectMessage().withClientIdentifier(id).startClean();
      c.onConnected = () {
        connected = true;
        onChange();
      };
      c.onDisconnected = () {
        connected = false;
        onChange();
      };
      c.onAutoReconnected = () {
        connected = true;
        _send({'type': 'hb'});
        onChange();
      };
      try {
        await c.connect();
        if (c.connectionStatus?.state != MqttConnectionState.connected) throw Exception('not connected');
      } catch (_) {
        c.disconnect();
        continue;
      }
      _client = c;
      connected = true;
      c.subscribe(_peerTopic, MqttQos.atMostOnce);
      c.updates?.listen((batch) => _onUpdates(batch));
      await _send({'type': 'hello'});
      onChange();
      return;
    }
  }

  Future<void> _onUpdates(List<dynamic> batch) async {
    for (final item in batch) {
      final p = (item as MqttReceivedMessage).payload;
      if (p is! MqttPublishMessage) continue;
      try {
        final data = p.payload.message.toList();
        final box = SecretBox.fromConcatenation(data, nonceLength: _algo.nonceLength, macLength: _algo.macAlgorithm.macLength);
        final clear = await _algo.decrypt(box, secretKey: _key);
        final msg = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        final ts = DateTime.fromMillisecondsSinceEpoch((msg['ts'] ?? 0) as int);
        if (DateTime.now().difference(ts).abs() > const Duration(minutes: 5)) continue; // ignore old/replayed
        final wasOnline = peerOnline;
        _lastSeen = DateTime.now();
        if (msg['name'] is String && (msg['name'] as String).isNotEmpty) peerName = msg['name'] as String;
        if (msg['type'] == 'hello' && !wasOnline) unawaited(_send({'type': 'hb'})); // answer so both turn green fast
        if (msg['type'] == 'bye') _lastSeen = null;
        if (msg['type'] != 'hb' && msg['type'] != 'hello' && msg['type'] != 'bye') onMessage(msg);
        onChange();
      } catch (_) {
        // not ours / tampered — ignore
      }
    }
  }

  Future<bool> _send(Map<String, dynamic> msg) async {
    final c = _client;
    if (c == null || c.connectionStatus?.state != MqttConnectionState.connected) return false;
    final body = {...msg, 'ts': DateTime.now().millisecondsSinceEpoch, 'name': myName, 'from': me};
    final box = await _algo.encrypt(utf8.encode(jsonEncode(body)), secretKey: _key);
    final buf = Uint8Buffer()..addAll(box.concatenation());
    c.publishMessage(_myTopic, MqttQos.atMostOnce, buf);
    return true;
  }

  /// Any message (encrypted) to the other device.
  Future<bool> send(Map<String, dynamic> msg) => _send(msg);

  /// Ask the other device to do something (same fields as a brain action).
  Future<bool> sendCommand(String action, String arg, String text) =>
      _send({'type': 'cmd', 'action': action, 'arg': arg, 'text': text});

  Future<void> stop() async {
    _closing = true;
    _hb?.cancel();
    _watch?.cancel();
    try {
      await _send({'type': 'bye'});
      await Future.delayed(const Duration(milliseconds: 200));
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    connected = false;
  }

  static String get thisDevice => Platform.isAndroid ? 'phone' : 'pc';
}
