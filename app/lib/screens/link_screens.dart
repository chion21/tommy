import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/app_state.dart';
import '../core/link.dart';
import '../widgets/link_badge.dart';

/// Settings section: link status + QR (PC) or scanner (phone) + unlink.
class LinkSection extends StatelessWidget {
  final AppState app;
  const LinkSection({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final isPc = DeviceLink.thisDevice == 'pc';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (app.linked)
        ListTile(
          leading: LinkBadge(app: app, compact: true),
          title: Text(app.peerLabel),
          subtitle: Text(app.t(app.peerOnline ? 'state_online' : 'state_offline')),
        )
      else
        ListTile(leading: const Icon(Icons.link_off), title: Text(app.t('link_none'))),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (isPc)
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_2),
            label: Text(app.t('link_show_qr')),
            onPressed: () async {
              final p = await app.newPairingQr();
              if (context.mounted) {
                await showDialog(context: context, builder: (_) => _QrDialog(app: app, pairing: p));
              }
            },
          )
        else
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(app.t('link_scan')),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScanScreen(app: app))),
          ),
        if (app.linked)
          OutlinedButton.icon(icon: const Icon(Icons.link_off), label: Text(app.t('link_remove')), onPressed: app.unpair),
      ]),
    ]);
  }
}

class _QrDialog extends StatelessWidget {
  final AppState app;
  final Pairing pairing;
  const _QrDialog({required this.app, required this.pairing});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final done = app.peerOnline;
        return AlertDialog(
          title: Text(app.t('link_title')),
          content: SizedBox(
            width: 300,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: pairing.qr(app.userName.isEmpty ? 'PC' : '${app.userName} PC'), size: 240),
              ),
              const SizedBox(height: 12),
              Text(app.t('link_qr_hint'), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              done
                  ? Text(app.t('link_done'), style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700))
                  : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text(app.t('link_waiting')),
                    ]),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(app.t('save')))],
        );
      },
    );
  }
}

/// Phone: camera scanner for the PC's QR code.
class ScanScreen extends StatefulWidget {
  final AppState app;
  final bool login; // true = login page: log in with the PC's account (no password)
  const ScanScreen({super.key, required this.app, this.login = false});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _handled = false;
  bool _busy = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      _handled = true;
      if (widget.login) {
        setState(() => _busy = true);
        try {
          final ok = await widget.app.loginWithQr(raw);
          if (!mounted) return;
          if (ok) {
            Navigator.pop(context);
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.app.t('link_bad_qr'))));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.app.err(e))));
        }
        if (mounted) setState(() => _busy = false);
        await Future.delayed(const Duration(seconds: 2));
        _handled = false;
        return;
      }
      final ok = await widget.app.pairFromQr(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(widget.app.t(ok ? 'link_done' : 'link_bad_qr'))));
      if (ok) {
        Navigator.pop(context);
      } else {
        await Future.delayed(const Duration(seconds: 2));
        _handled = false;
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.app.t(widget.login ? 'qr_login' : 'link_scan'))),
      body: Stack(children: [
        MobileScanner(onDetect: _onDetect),
        if (widget.login)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(12)),
              child: Text(widget.app.t(_busy ? 'qr_login_wait' : 'qr_login_hint'), style: const TextStyle(color: Colors.white)),
            ),
          ),
        if (_busy) const Center(child: CircularProgressIndicator()),
      ]),
    );
  }
}
