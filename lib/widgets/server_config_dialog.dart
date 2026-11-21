import 'package:flutter/material.dart';

import '../services/chat_service.dart';
import '../services/connectivity_service.dart';
import '../services/websocket_relay_service.dart';
import '../utils/constants.dart';

/// Settings for the class WebSocket relay (not the legacy Field Sync REST API).
class ServerConfigDialog extends StatefulWidget {
  const ServerConfigDialog({super.key});

  @override
  State<ServerConfigDialog> createState() => _ServerConfigDialogState();
}

class _ServerConfigDialogState extends State<ServerConfigDialog> {
  final _relayService = WebSocketRelayService();
  late final TextEditingController _urlController;
  bool _isSaving = false;
  String? _feedback;
  bool _feedbackIsError = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _relayService.relayUrl);
    _loadSavedUrl();
  }

  Future<void> _loadSavedUrl() async {
    await _relayService.initialize();
    if (!mounted) return;
    _urlController.text = _relayService.relayUrl;
    setState(() {});
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save({required bool reconnect}) async {
    setState(() {
      _isSaving = true;
      _feedback = null;
    });

    try {
      await _relayService.setRelayUrl(_urlController.text);
      if (reconnect) {
        // Reconnects only when ChatScreen has started the chat service.
        ChatService().reconnectRelay();
      }
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _feedback = reconnect
            ? 'Relay URL saved. Reconnection requested; wait for WELCOME.'
            : 'Relay URL saved. The app will use it when you join the chat.';
        _feedbackIsError = false;
      });
      if ((!reconnect || !ChatService().isStarted) && mounted) {
        Navigator.pop(context);
      }
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _feedback = error.message;
        _feedbackIsError = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _feedback = 'Could not save relay URL: $error';
        _feedbackIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.wifi_tethering, size: 23),
          SizedBox(width: 8),
          Text('Relay Settings'),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Vanish Relay Protocol v1 proposal',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'WebSocket Relay URL',
                  hintText: 'wss://your-relay.example/ws',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  _urlController.text = AppConstants.defaultWebSocketUrl;
                },
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('Use proposed class relay address'),
              ),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: Listenable.merge([_relayService, ConnectivityService()]),
                builder: (context, _) {
                  final hasNetwork = ConnectivityService().isNetworkAvailable;
                  final status = _relayService.status;
                  final label = !hasNetwork
                      ? 'No device network'
                      : _relayService.isConnected
                          ? 'Connected — WELCOME received'
                          : status == WebSocketConnectionStatus.connecting
                              ? 'Connecting / waiting for WELCOME'
                              : status == WebSocketConnectionStatus.error
                                  ? 'Connection error'
                                  : 'Disconnected';
                  final color = !hasNetwork || status == WebSocketConnectionStatus.error
                      ? theme.colorScheme.error
                      : _relayService.isConnected
                          ? Colors.teal
                          : theme.colorScheme.onSurfaceVariant;
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                        if (_relayService.lastError != null) ...[
                          const SizedBox(height: 4),
                          Text(_relayService.lastError!, style: const TextStyle(fontSize: 11)),
                        ],
                      ],
                    ),
                  );
                },
              ),
              if (_feedback != null) ...[
                const SizedBox(height: 10),
                Text(
                  _feedback!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _feedbackIsError ? theme.colorScheme.error : Colors.teal,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Chat messages use this WebSocket relay. The old Field Sync HTTP endpoints are not used for class chat.',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        OutlinedButton(
          onPressed: _isSaving ? null : () => _save(reconnect: false),
          child: const Text('Save URL'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : () => _save(reconnect: true),
          child: _isSaving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save & Reconnect'),
        ),
      ],
    );
  }
}
