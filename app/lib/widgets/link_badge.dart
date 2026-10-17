import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/link.dart';

/// Shows the OTHER device: on the PC a phone icon, on the phone a PC icon — green dot when online, grey when offline.
class LinkBadge extends StatelessWidget {
  final AppState app;
  final bool compact;
  const LinkBadge({super.key, required this.app, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!app.linked) return const SizedBox.shrink();
    final online = app.peerOnline;
    final otherIsPhone = DeviceLink.thisDevice == 'pc';
    final color = online ? Colors.greenAccent : Colors.grey;
    final label = '${app.t(otherIsPhone ? 'dev_phone' : 'dev_pc')} · ${app.t(online ? 'state_online' : 'state_offline')}';
    return Tooltip(
      message: '${app.peerLabel} — ${app.t(online ? 'state_online' : 'state_offline')}',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.7)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(otherIsPhone ? Icons.smartphone : Icons.computer, size: 16, color: color),
          const SizedBox(width: 4),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: online ? [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)] : null,
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ]),
      ),
    );
  }
}
