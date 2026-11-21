import 'package:flutter/material.dart';
import '../services/connectivity_service.dart';
import '../services/websocket_relay_service.dart';
import 'server_config_dialog.dart';

class ConnectionStatusBadge extends StatelessWidget {
  final bool showLabel;
  final bool compact;

  const ConnectionStatusBadge({
    super.key,
    this.showLabel = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final connectivityService = ConnectivityService();
    final relayService = WebSocketRelayService();

    return ListenableBuilder(
      listenable: Listenable.merge([
        connectivityService,
        relayService,
      ]),
      builder: (context, _) {
        final hasNetwork = connectivityService.isNetworkAvailable;
        final relayStatus = relayService.status;

        Color color;
        IconData icon;
        String text;

        if (!hasNetwork) {
          // Distinction: Phone network interface is disconnected
          color = Colors.grey.shade700;
          icon = Icons.wifi_off_outlined;
          text = 'No Network';
        } else if (relayService.isConnected) {
          // Connected to the actual class WebSocket relay
          color = Colors.teal;
          icon = Icons.cloud_done;
          text = 'Connected';
        } else if (relayStatus == WebSocketConnectionStatus.connecting) {
          color = Colors.amber.shade700;
          icon = Icons.cloud_sync;
          text = 'Connecting...';
        } else if (relayStatus == WebSocketConnectionStatus.error) {
          color = Colors.red.shade600;
          icon = Icons.cloud_off;
          text = 'Server Offline';
        } else {
          color = Colors.grey.shade600;
          icon = Icons.cloud_queue;
          text = 'Disconnected';
        }

        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            showDialog(
              context: context,
              builder: (ctx) => const ServerConfigDialog(),
            );
          },
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: compact ? 4 : 6,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: compact ? 14 : 16, color: color),
                if (showLabel) ...[
                  const SizedBox(width: 6),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
