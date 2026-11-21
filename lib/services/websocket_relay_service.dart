import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/constants.dart';
import 'time_sync_service.dart';

enum WebSocketConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// WebSocket client for the proposed Vanish Relay Protocol v1.
/// The relay remains the authority for sent_at and expires_at.
class WebSocketRelayService extends ChangeNotifier {
  static final WebSocketRelayService _instance =
      WebSocketRelayService._internal();
  factory WebSocketRelayService() => _instance;
  WebSocketRelayService._internal();

  final TimeSyncService _timeSyncService = TimeSyncService();

  String _relayUrl = AppConstants.defaultWebSocketUrl;
  int _protocolVersion = AppConstants.protocolVersion;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;

  WebSocketConnectionStatus _status = WebSocketConnectionStatus.disconnected;
  String? _lastError;
  bool _isJoined = false;
  bool _shouldAutoReconnect = true;
  bool _failureHandled = false;
  bool _reconnectScheduled = false;
  int _connectionGeneration = 0;

  String _deviceId = '';
  String _displayName = '';

  Timer? _pingTimer;
  Timer? _watchdogTimer;
  Timer? _welcomeTimer;
  Timer? _reconnectTimer;
  DateTime? _lastPongReceived;
  int _reconnectAttempt = 0;

  @visibleForTesting
  WebSocketChannel Function(Uri uri)? channelFactory;

  void Function(String id, String sender, String text, int sentAt, int expiresAt)?
      onMessageReceived;
  void Function(String id, int count)? onDelivered;
  void Function(String id)? onExpired;
  void Function(int count, List<String> members)? onPresenceReceived;
  void Function(String code, String message)? onErrorReceived;
  void Function(WebSocketConnectionStatus status)? onStatusChanged;
  void Function()? onWelcomeReceived;

  String get relayUrl => _relayUrl;
  int get protocolVersion => _protocolVersion;
  WebSocketConnectionStatus get status => _status;
  bool get isConnected =>
      _status == WebSocketConnectionStatus.connected && _isJoined;
  bool get isJoined => _isJoined;
  bool get isConnecting => _status == WebSocketConnectionStatus.connecting;
  String? get lastError => _lastError;
  int get reconnectAttempt => _reconnectAttempt;
  DateTime? get lastPongReceived => _lastPongReceived;
  bool get isPingTimerActive => _pingTimer != null;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(AppConstants.prefKeyWebSocketUrl);
    if (saved != null && saved.trim().isNotEmpty) {
      _relayUrl = saved.trim();
    }
  }

  Future<void> setRelayUrl(String url) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
      throw const FormatException('Relay URL must be a valid wss:// address.');
    }
    _relayUrl = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyWebSocketUrl, trimmed);
    notifyListeners();
  }

  void setProtocolVersion(int version) {
    _protocolVersion = version;
    notifyListeners();
  }

  /// Opens the socket, waits for the WebSocket handshake, then sends JOIN.
  Future<void> connect({
    required String deviceId,
    required String name,
  }) async {
    _deviceId = deviceId.trim();
    _displayName = name.trim();
    _shouldAutoReconnect = true;

    if (_deviceId.isEmpty) {
      _setError('Device ID is missing.');
      return;
    }
    if (_displayName.isEmpty ||
        _displayName.length > AppConstants.maxDisplayNameLength) {
      _setError('Display name must contain 1-30 characters.');
      return;
    }

    // Invalidate callbacks from any previous socket before closing it.
    final generation = ++_connectionGeneration;
    _cancelTimers();
    _closeSocket();
    _failureHandled = false;
    _reconnectScheduled = false;
    _setStatus(WebSocketConnectionStatus.connecting);
    _isJoined = false;

    try {
      final uri = Uri.parse(_relayUrl);
      _channel = channelFactory != null
          ? channelFactory!(uri)
          : WebSocketChannel.connect(uri);

      // The relay host may sleep while idle; allow up to 75 seconds for handshake.
      await _channel!.ready.timeout(const Duration(seconds: 75));
      if (generation != _connectionGeneration || !_shouldAutoReconnect) {
        return;
      }

      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (generation == _connectionGeneration) {
            _handleIncomingData(data);
          }
        },
        onError: (Object error) => _handleConnectionError(error, generation),
        onDone: () => _handleConnectionDone(generation),
        cancelOnError: true,
      );

      _sendRawJson({
        'type': 'join',
        'protocol': _protocolVersion,
        'device_id': _deviceId,
        'name': _displayName,
      });
      _welcomeTimer?.cancel();
      _welcomeTimer = Timer(const Duration(seconds: 15), () {
        if (!_isJoined) {
          _handleConnectionError(
            'Relay did not send WELCOME within 15 seconds after JOIN.',
            generation,
          );
        }
      });
    } catch (error) {
      _handleConnectionError(error, generation);
    }
  }

  void _handleIncomingData(dynamic rawData) {
    try {
      final String frame;
      if (rawData is String) {
        frame = rawData;
      } else if (rawData is List<int>) {
        frame = utf8.decode(rawData);
      } else {
        onErrorReceived?.call('bad_json', 'Relay frame was not JSON text.');
        return;
      }

      final decoded = jsonDecode(frame);
      if (decoded is! Map) {
        onErrorReceived?.call('bad_json', 'Relay frame must be a JSON object.');
        return;
      }
      _processProtocolMessage(Map<String, dynamic>.from(decoded));
    } catch (error) {
      onErrorReceived?.call('bad_json', 'Could not parse relay frame: $error');
    }
  }

  void _processProtocolMessage(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String) {
      onErrorReceived?.call('unknown_type', 'Relay frame has no valid type.');
      return;
    }

    switch (type) {
      case 'welcome':
        final protocol = json['protocol'];
        final serverTime = json['server_time'];
        if (protocol != _protocolVersion || serverTime is! int) {
          _handleProtocolFailure(
            'bad_protocol',
            'WELCOME must contain the expected protocol version and integer server_time.',
          );
          return;
        }
        _timeSyncService.updateFromRelayServerTime(serverTime);
        _welcomeTimer?.cancel();
        _welcomeTimer = null;
        _isJoined = true;
        _reconnectAttempt = 0;
        _lastError = null;
        _lastPongReceived = DateTime.now();
        _setStatus(WebSocketConnectionStatus.connected);
        _startHeartbeat();
        onWelcomeReceived?.call();
        break;

      case 'message':
        if (!_isJoined) {
          onErrorReceived?.call('not_joined', 'Message received before WELCOME.');
          return;
        }
        final id = json['id'];
        final sender = json['sender'];
        final text = json['text'];
        final sentAt = json['sent_at'];
        final expiresAt = json['expires_at'];

        if (id is! String || id.isEmpty ||
            sender is! String || sender.isEmpty || sender.length > 30 ||
            text is! String || text.isEmpty || text.length > 500 ||
            sentAt is! int || expiresAt is! int ||
            expiresAt - sentAt != AppConstants.messageTtl.inMilliseconds) {
          onErrorReceived?.call(
            'bad_message',
            'Message frame is missing valid fields or does not have a 30-second expiry.',
          );
          return;
        }
        onMessageReceived?.call(id, sender, text, sentAt, expiresAt);
        break;

      case 'delivered':
        if (!_isJoined) {
          onErrorReceived?.call('not_joined', 'DELIVERED received before WELCOME.');
          return;
        }
        final id = json['id'];
        final count = json['count'];
        if (id is String && id.isNotEmpty && count is int && count >= 0) {
          onDelivered?.call(id, count);
        } else {
          onErrorReceived?.call('bad_message', 'Invalid DELIVERED frame.');
        }
        break;

      case 'expired':
        if (!_isJoined) {
          onErrorReceived?.call('not_joined', 'EXPIRED received before WELCOME.');
          return;
        }
        final id = json['id'];
        if (id is String && id.isNotEmpty) {
          onExpired?.call(id);
        } else {
          onErrorReceived?.call('bad_message', 'Invalid EXPIRED frame.');
        }
        break;

      case 'presence':
        final count = json['count'];
        final rawMembers = json['members'];
        if (count is int && count >= 0 && rawMembers is List) {
          final members = rawMembers.whereType<String>().toList();
          onPresenceReceived?.call(count, members);
        } else {
          onErrorReceived?.call(
            'bad_message',
            'PRESENCE frame must contain integer count and a list of members.',
          );
        }
        break;

      case 'pong':
        if (_isJoined) _lastPongReceived = DateTime.now();
        break;

      case 'error':
        final code = json['code'] is String ? json['code'] as String : 'unknown_error';
        final message = json['message'] is String
            ? json['message'] as String
            : 'Relay returned an unspecified error.';
        onErrorReceived?.call(code, message);
        // A JOIN rejection is not a transient network failure. Stop retrying
        // until the user explicitly reconnects or corrects the settings.
        if (!_isJoined) {
          _failureHandled = true;
          _lastError = 'Relay rejected JOIN ($code): $message';
          _welcomeTimer?.cancel();
          _welcomeTimer = null;
          _cancelHeartbeat();
          _setStatus(WebSocketConnectionStatus.error);
          _closeSocket();
          _shouldAutoReconnect = false;
        }
        break;

      default:
        onErrorReceived?.call('unknown_type', 'Unknown relay frame type: $type');
    }
  }

  void _handleProtocolFailure(String code, String message) {
    onErrorReceived?.call(code, message);
    _handleConnectionError(message, _connectionGeneration);
  }

  bool sendMessage({required String id, required String text}) {
    final trimmed = text.trim();
    if (!isConnected || id.trim().isEmpty || trimmed.isEmpty || trimmed.length > 500) {
      return false;
    }
    return _sendRawJson({
      'type': 'message',
      'id': id,
      'sender': _displayName,
      'text': trimmed,
    });
  }

  void _startHeartbeat() {
    _cancelHeartbeat();
    _lastPongReceived = DateTime.now();

    _pingTimer = Timer.periodic(AppConstants.pingInterval, (_) {
      if (isConnected) _sendRawJson({'type': 'ping'});
    });

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final lastPong = _lastPongReceived;
      if (isConnected && lastPong != null &&
          DateTime.now().difference(lastPong) >= AppConstants.pongTimeout) {
        _handleConnectionError(
          'Heartbeat timeout: no pong received for 30 seconds.',
          _connectionGeneration,
        );
      }
    });
  }

  /// Re-check heartbeat after the app returns from background.
  void checkHeartbeatNow() {
    final lastPong = _lastPongReceived;
    if (isConnected && lastPong != null &&
        DateTime.now().difference(lastPong) >= AppConstants.pongTimeout) {
      _handleConnectionError(
        'Heartbeat timeout after app resume.',
        _connectionGeneration,
      );
    }
  }

  bool _sendRawJson(Map<String, dynamic> jsonMap) {
    try {
      final channel = _channel;
      if (channel == null) return false;
      channel.sink.add(jsonEncode(jsonMap));
      return true;
    } catch (error) {
      _handleConnectionError(error, _connectionGeneration);
      return false;
    }
  }

  void _handleConnectionError(Object error, int generation) {
    if (generation != _connectionGeneration || _failureHandled) return;
    _failureHandled = true;
    _lastError = 'Relay connection error: $error';
    _isJoined = false;
    _cancelHeartbeat();
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    _setStatus(WebSocketConnectionStatus.error);
    _closeSocket();
    _scheduleReconnect();
  }

  void _handleConnectionDone(int generation) {
    if (generation != _connectionGeneration || _failureHandled) return;
    _failureHandled = true;
    _isJoined = false;
    _cancelHeartbeat();
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    _setStatus(WebSocketConnectionStatus.disconnected);
    _closeSocket();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldAutoReconnect || _reconnectScheduled) return;
    _reconnectScheduled = true;

    final delays = AppConstants.reconnectDelaysSeconds;
    final seconds = _reconnectAttempt < delays.length
        ? delays[_reconnectAttempt]
        : delays.last;
    _reconnectAttempt++;
    _setStatus(WebSocketConnectionStatus.connecting);

    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      _reconnectScheduled = false;
      if (_shouldAutoReconnect && _deviceId.isNotEmpty && _displayName.isNotEmpty) {
        connect(deviceId: _deviceId, name: _displayName);
      }
    });
  }

  void _setStatus(WebSocketConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
    onStatusChanged?.call(status);
  }

  void _setError(String error) {
    _lastError = error;
    _isJoined = false;
    _setStatus(WebSocketConnectionStatus.error);
  }

  void _cancelHeartbeat() {
    _pingTimer?.cancel();
    _watchdogTimer?.cancel();
    _pingTimer = null;
    _watchdogTimer = null;
  }

  void _cancelTimers() {
    _cancelHeartbeat();
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectScheduled = false;
  }

  void _closeSocket() {
    final subscription = _channelSubscription;
    _channelSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        unawaited(channel.sink.close());
      } catch (_) {}
    }
    _isJoined = false;
  }

  void disconnect() {
    _shouldAutoReconnect = false;
    ++_connectionGeneration;
    _cancelTimers();
    _closeSocket();
    _setStatus(WebSocketConnectionStatus.disconnected);
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }

  @visibleForTesting
  void setStatusForTesting(
    WebSocketConnectionStatus status, {
    bool joined = false,
  }) {
    _isJoined = joined;
    _setStatus(status);
  }

  @visibleForTesting
  void simulateIncomingData(String jsonText) => _handleIncomingData(jsonText);

  @visibleForTesting
  void simulatePongTimeout() {
    _handleConnectionError('Heartbeat timeout (simulated)', _connectionGeneration);
  }

  @visibleForTesting
  void resetStateForTesting() {
    disconnect();
    _reconnectAttempt = 0;
    _lastError = null;
    _lastPongReceived = null;
    _isJoined = false;
    _shouldAutoReconnect = true;
    _failureHandled = false;
    channelFactory = null;
  }
}
