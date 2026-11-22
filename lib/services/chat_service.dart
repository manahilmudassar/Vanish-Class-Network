import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../utils/constants.dart';
import 'connectivity_service.dart';
import 'device_service.dart';
import 'message_database_service.dart';
import 'time_sync_service.dart';
import 'websocket_relay_service.dart';

/// Central coordinator for chat messaging in Vanish Class Network.
/// 
/// Integrates Vanish Relay Protocol v1 via WebSocketRelayService:
/// - Transport: WebSocket (wss://vanish-relay-sawaira.bonto.page/ws)
/// - Protocol Version: 1
/// - Event handling: JOIN, WELCOME, SEND, RECEIVE, DELIVERED, EXPIRED, PING/PONG, ERROR
/// - Offline queue: drops messages older than 30s; flushes valid items on connect
/// - Lifecycle: recalculates 30s expiry immediately on foreground return
/// - Duplicates: keeps seen ID set and ignores repeated IDs
class ChatService extends ChangeNotifier with WidgetsBindingObserver {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final DeviceService _deviceService = DeviceService();
  final TimeSyncService _timeSyncService = TimeSyncService();
  final ConnectivityService _connectivityService = ConnectivityService();
  final WebSocketRelayService _relayService = WebSocketRelayService();
  final MessageDatabaseService _messageDatabase =
  MessageDatabaseService.instance;

  final List<ChatMessage> _messages = [];
  final Set<String> _seenMessageIds = {};
  final List<ChatMessage> _offlineQueue = [];
  int _presenceCount = 0;
  List<String> _presenceMembers = [];

  Timer? _countdownTimer;
  final String _activeRoom = AppConstants.defaultRoomName;
  String? _lastSendError;

  bool _isStarted = false;
  bool _isObserverRegistered = false;
  AppLifecycleState _lastLifecycleState = AppLifecycleState.resumed;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ChatMessage> get offlineQueue => List.unmodifiable(_offlineQueue);
  String get activeRoom => _activeRoom;
  String? get lastSendError => _lastSendError;
  int get activeMessageCount => _messages.length;
  int get presenceCount => _presenceCount;
  List<String> get presenceMembers => List.unmodifiable(_presenceMembers);

  bool get isStarted => _isStarted;
  bool get isObserverRegistered => _isObserverRegistered;
  AppLifecycleState get lastLifecycleState => _lastLifecycleState;
  bool get isCountdownTimerActive => _countdownTimer != null;
  bool get isSyncTimerActive => _countdownTimer != null; // For test compatibility
  WebSocketRelayService get relayService => _relayService;

  /// Starts chat messaging: registers lifecycle observer, connectivity listener,
  /// starts local 250ms countdown ticker, and connects to WebSocket relay.
  void start() {
    if (_isStarted) return;
    _isStarted = true;
    _registerLifecycleObserver();
    _connectivityService.onConnectivityRestored = _handleConnectivityRestored;
    _connectivityService.onConnectivityLost = _handleConnectivityLost;
    _setupRelayListeners();
    _startTimers();
    unawaited(_initializeConnectivityAndConnect());
  }

  Future<void> _initializeConnectivityAndConnect() async {
    await _initDatabaseAndLoadMessages();
    await _relayService.initialize();
    await _connectivityService.initialize();
    if (_isStarted && _connectivityService.isNetworkAvailable) {
      _connectRelay();
    }
  }

  /// Prunes expired messages and loads non-expired active messages from local SQLite.
  Future<void> _initDatabaseAndLoadMessages() async {
    try {
      final syncNow = _timeSyncService.synchronizedNow;
      // 1. Clean up any messages in the local database that expired while app was closed
      await _messageDatabase.deleteExpiredMessages(syncNow);

      // 2. Load active non-expired messages from the database
      final activeMessages = await _messageDatabase.getActiveMessages(syncNow);
      if (activeMessages.isNotEmpty) {
        for (final msg in activeMessages) {
          if (!_seenMessageIds.contains(msg.id)) {
            _seenMessageIds.add(msg.id);
            _messages.add(msg);
          }
        }
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        developer.log(
          'Loaded ${activeMessages.length} active message(s) from local SQLite database',
          name: 'ChatService',
        );
        notifyListeners();
      }
    } catch (e, stack) {
      developer.log(
        'Failed to load active messages from SQLite on startup: $e',
        name: 'ChatService',
        error: e,
        stackTrace: stack,
      );
    }
  }

  void _setupRelayListeners() {
    _relayService.onWelcomeReceived = _handleRelayWelcome;
    _relayService.onMessageReceived = _handleRelayMessage;
    _relayService.onDelivered = _handleRelayDelivered;
    _relayService.onExpired = _handleRelayExpired;
    _relayService.onPresenceReceived = _handleRelayPresence;
    _relayService.onErrorReceived = _handleRelayError;
    _relayService.onStatusChanged = (status) {
      if (status != WebSocketConnectionStatus.connected) {
        _presenceCount = 0;
        _presenceMembers = [];
      }
      notifyListeners();
    };
  }

  void _connectRelay() {
    if (!_isStarted || !_connectivityService.isNetworkAvailable) return;
    if (_deviceService.deviceId.isEmpty) return;
    if (_relayService.isConnected || _relayService.isConnecting) return;

    final name = _deviceService.displayName.isEmpty
        ? 'Student'
        : _deviceService.displayName;
    unawaited(_relayService.connect(
      deviceId: _deviceService.deviceId,
      name: name,
    ));
  }

  /// Triggered when the relay returns WELCOME (handshake complete).
  /// Flushes any non-expired offline queued messages over the WebSocket.
  void _handleRelayWelcome() {
    _flushOfflineQueue();
    notifyListeners();
  }

  /// Flushes pending offline messages that have not expired.
  void _flushOfflineQueue() {
    final syncNow = _timeSyncService.synchronizedNow;
    final expiredQueued = _offlineQueue.where((msg) => msg.isExpired(syncNow)).toList();
    for (final expired in expiredQueued) {
      _offlineQueue.removeWhere((msg) => msg.id == expired.id);
      _messages.removeWhere((msg) => msg.id == expired.id);
      unawaited(_messageDatabase.deleteMessage(expired.id));
    }
    if (!_relayService.isConnected) return;

    // Remove an item only after the frame is accepted by the active socket.
    for (final msg in List<ChatMessage>.from(_offlineQueue)) {
      if (msg.isExpired(_timeSyncService.synchronizedNow)) {
        _offlineQueue.removeWhere((queued) => queued.id == msg.id);
        _messages.removeWhere((active) => active.id == msg.id);
        unawaited(_messageDatabase.deleteMessage(msg.id));
        continue;
      }
      if (_relayService.sendMessage(id: msg.id, text: msg.content)) {
        _offlineQueue.removeWhere((queued) => queued.id == msg.id);
        if (_connectivityService.isNetworkAvailable) {
          unawaited(_messageDatabase.saveMessage(msg));
          developer.log('Flushed queued message saved to database: id=${msg.id}', name: 'ChatService');
        }
        _lastSendError = null;
      } else {
        _lastSendError = 'Could not send queued message; it remains queued.';
        break;
      }
    }
    notifyListeners();
  }

  /// Triggered when an incoming message frame arrives from the relay:
  /// {"type":"message","id":"...","sender":"...","text":"...","sent_at":...,"expires_at":...}
  void _handleRelayMessage(
    String id,
    String sender,
    String text,
    int sentAt,
    int expiresAt,
  ) {
    final syncNow = _timeSyncService.synchronizedNow;

    // Check if this is an echo of our own pending message
    final existingIndex = _messages.indexWhere((m) => m.id == id);
    if (existingIndex != -1) {
      final existing = _messages[existingIndex];
      if (existing.status == MessageStatus.pending) {
        final serverSentAt =
            DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true);
        final serverExpiresAt =
            DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true);
        final updatedMessage = existing.copyWith(
          status: MessageStatus.delivered,
          createdAt: serverSentAt,
          deliveredAt: serverSentAt,
          expiresAt: serverExpiresAt,
        );
        _messages[existingIndex] = updatedMessage;
        final isNetAvailable = _connectivityService.isNetworkAvailable;
        debugPrint('[SQLITE DIAGNOSTIC] Outgoing Echo received for ID: "$id"');
        debugPrint('[SQLITE DIAGNOSTIC] _connectivityService.isNetworkAvailable = $isNetAvailable');
        if (isNetAvailable) {
          debugPrint('[SQLITE DIAGNOSTIC] Calling _messageDatabase.saveMessage(updatedMessage) for echo...');
          unawaited(_messageDatabase.saveMessage(updatedMessage));
          developer.log('Outgoing message echo updated: id=$id', name: 'ChatService');
        } else {
          debugPrint('[SQLITE DIAGNOSTIC] SKIPPING saveMessage() for echo because isNetworkAvailable is FALSE!');
        }
        notifyListeners();
      }
      return;
    }

    // PROTOCOL.md Section 8: DUPLICATES - ignore repeats
    if (_seenMessageIds.contains(id)) {
      return;
    }
    _seenMessageIds.add(id);

    final serverSentAt =
        DateTime.fromMillisecondsSinceEpoch(sentAt, isUtc: true);
    final serverExpiresAt =
        DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true);

    // Discard if already expired by synchronized server time
    if (syncNow.isAfter(serverExpiresAt) ||
        syncNow.isAtSameMomentAs(serverExpiresAt)) {
      return;
    }

    // The relay protocol does not include a sender device ID. Our own echo is
    // identified above by its pending message ID; all other IDs are peers.
    final message = ChatMessage(
      id: id,
      senderId: 'peer_$id',
      senderName: sender,
      content: text,
      room: _activeRoom,
      createdAt: serverSentAt,
      deliveredAt: serverSentAt,
      expiresAt: serverExpiresAt,
      status: MessageStatus.delivered,
    );

    _messages.add(message);
    final isNetAvailable = _connectivityService.isNetworkAvailable;
    debugPrint('================================================================');
    debugPrint('[SQLITE DIAGNOSTIC] Incoming Peer Message Received:');
    debugPrint('[SQLITE DIAGNOSTIC] ID: "$id", Sender: "$sender", Content: "$text"');
    debugPrint('[SQLITE DIAGNOSTIC] _connectivityService.isNetworkAvailable = $isNetAvailable');
    if (isNetAvailable) {
      debugPrint('[SQLITE DIAGNOSTIC] Calling _messageDatabase.saveMessage(message) for peer message...');
      unawaited(_messageDatabase.saveMessage(message));
      developer.log(
        'Received peer message saved to local SQLite database: id=$id, sender=$sender',
        name: 'ChatService',
      );
    } else {
      debugPrint('[SQLITE DIAGNOSTIC] SKIPPING saveMessage() for peer message because isNetworkAvailable is FALSE!');
      developer.log(
        'Internet OFF: Received peer message NOT saved to database: id=$id',
        name: 'ChatService',
      );
    }
    debugPrint('================================================================');
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    notifyListeners();
  }

  /// Triggered when the relay notifies DELIVERED to the sender:
  /// {"type":"delivered","id":"...","count":2}
  void _handleRelayDelivered(String id, int count) {
    final index = _messages.indexWhere((m) => m.id == id);
    if (index != -1) {
      final msg = _messages[index];
      final updated = msg.copyWith(
        status: MessageStatus.delivered,
        deliveryCount: count,
      );
      _messages[index] = updated;
      final isNetAvailable = _connectivityService.isNetworkAvailable;
      debugPrint('[SQLITE DIAGNOSTIC] Delivery confirmation received for ID: "$id" (count: $count)');
      debugPrint('[SQLITE DIAGNOSTIC] _connectivityService.isNetworkAvailable = $isNetAvailable');
      if (isNetAvailable) {
        debugPrint('[SQLITE DIAGNOSTIC] Calling _messageDatabase.saveMessage(updated) for delivery status...');
        unawaited(_messageDatabase.saveMessage(updated));
        developer.log(
          'Delivery count updated in SQLite database: id=$id, count=$count',
          name: 'ChatService',
        );
      } else {
        debugPrint('[SQLITE DIAGNOSTIC] SKIPPING saveMessage() for delivery status because isNetworkAvailable is FALSE!');
      }
      notifyListeners();
    }
  }

  /// Triggered when the relay notifies EXPIRED:
  /// {"type":"expired","id":"..."}
  /// PROTOCOL.md Section 5: Apps remove message when they receive this or when expires_at passes.
  void _handleRelayExpired(String id) {
    final beforeMessages = _messages.length;
    final beforeQueue = _offlineQueue.length;
    _messages.removeWhere((m) => m.id == id);
    _offlineQueue.removeWhere((m) => m.id == id);
    unawaited(_messageDatabase.deleteMessage(id));
    developer.log('Relay EXPIRED event: deleted id=$id from SQLite and RAM', name: 'ChatService');
    if (_messages.length != beforeMessages || _offlineQueue.length != beforeQueue) {
      notifyListeners();
    }
  }

  /// Triggered when the relay notifies PRESENCE:
  /// {"type":"presence","count":3,"members":["Sawaira","Ali","Sara"]}
  /// PROTOCOL.md Section 12: Sent whenever someone joins or leaves.
  /// members is in join order.
  void _handleRelayPresence(int count, List<String> members) {
    _presenceCount = count;
    // Keep members in the exact order received from the relay
    _presenceMembers = List<String>.from(members);
    notifyListeners();
  }

  void _handleRelayError(String code, String message) {
    _lastSendError = 'Relay Error ($code): $message';
    notifyListeners();
  }

  void _registerLifecycleObserver() {
    if (!_isObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _isObserverRegistered = true;
    }
  }

  void _unregisterLifecycleObserver() {
    if (_isObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverRegistered = false;
    }
  }

  void _startTimers() {
    _stopTimers();
    // High-resolution countdown ticker for smooth second transitions and immediate vanishing
    _countdownTimer = Timer.periodic(AppConstants.countdownTickInterval, (_) {
      _tickAndPruneExpired();
    });
  }

  void _stopTimers() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  /// Stops messaging, disconnects relay, cancels timers, and unregisters lifecycle observer.
  void stop() {
    _isStarted = false;
    _connectivityService.onConnectivityRestored = null;
    _connectivityService.onConnectivityLost = null;
    _relayService.onWelcomeReceived = null;
    _relayService.onMessageReceived = null;
    _relayService.onDelivered = null;
    _relayService.onExpired = null;
    _relayService.onPresenceReceived = null;
    _relayService.onErrorReceived = null;
    _relayService.onStatusChanged = null;
    _relayService.disconnect();
    _presenceCount = 0;
    _presenceMembers = [];
    _stopTimers();
    _unregisterLifecycleObserver();
  }

  /// Triggered when device network connectivity is restored.
  void _handleConnectivityRestored() {
    if (!_isStarted) return;
    _connectRelay();
  }

  void _handleConnectivityLost() {
    if (_isStarted) _relayService.disconnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    handleAppLifecycleState(state);
  }

  /// Handles app lifecycle state transitions.
  void handleAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    if (!_isStarted) return;

    switch (state) {
      case AppLifecycleState.resumed:
        _handleAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _handleAppBackgrounded();
        break;
    }
  }

  void _handleAppBackgrounded() {
    _stopTimers();
  }

  void _handleAppResumed() {
    _relayService.checkHeartbeatNow();
    final syncNow = _timeSyncService.synchronizedNow;

    // 1. Immediately prune expired active messages
    _messages.removeWhere((msg) => msg.isExpired(syncNow));

    // 2. Immediately prune expired offline queued messages
    _offlineQueue.removeWhere((msg) => msg.isExpired(syncNow));
  
    // 3. Remove expired messages from local database
    unawaited(_messageDatabase.deleteExpiredMessages(syncNow));
    developer.log('App resumed: pruned expired messages from RAM and SQLite', name: 'ChatService');

    // 4. Immediately notify UI listeners so display updates in this frame
    notifyListeners();

    // 5. Restart timers cleanly without duplicates
    _startTimers();

    // 6. Reconnect to WebSocket relay if disconnected
    if (!_relayService.isConnected && _connectivityService.isNetworkAvailable) {
      _connectRelay();
    }
  }

  /// Evaluates active messages against synchronized server time.
  /// Removes any message whose 30s lifespan has elapsed.
  void _tickAndPruneExpired() {
    final syncNow = _timeSyncService.synchronizedNow;

    final expired = _messages.where((msg) => msg.isExpired(syncNow)).toList();
    final expiredQueue = _offlineQueue.where((msg) => msg.isExpired(syncNow)).toList();

    if (expired.isNotEmpty || expiredQueue.isNotEmpty) {
      for (final msg in expired) {
        unawaited(_messageDatabase.deleteMessage(msg.id));
      }
      for (final msg in expiredQueue) {
        unawaited(_messageDatabase.deleteMessage(msg.id));
      }
      _messages.removeWhere((msg) => msg.isExpired(syncNow));
      _offlineQueue.removeWhere((msg) => msg.isExpired(syncNow));
      unawaited(_messageDatabase.deleteExpiredMessages(syncNow));
      developer.log(
        'Auto-pruned ${expired.length} expired message(s) from UI and SQLite',
        name: 'ChatService',
      );
      notifyListeners();
    } else {
      if (_messages.isNotEmpty) {
        notifyListeners();
      }
    }
  }

  /// Sends a new chat message according to Vanish Relay Protocol v1:
  /// `{"type":"message","id":"<unique id>","sender":"<display name>","text":"<message>"}`
  Future<bool> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > AppConstants.maxMessageLength) {
      return false;
    }

    final syncNow = _timeSyncService.synchronizedNow;
    final messageId = const Uuid().v4();

    // Assignment rule: Duplicate message IDs must be ignored
    _seenMessageIds.add(messageId);

    final outgoing = ChatMessage(
      id: messageId,
      senderId: _deviceService.deviceId,
      senderName: _deviceService.displayName.isEmpty
          ? 'Student'
          : _deviceService.displayName,
      content: trimmed,
      room: _activeRoom,
      createdAt: syncNow,
      deliveredAt: null,
      expiresAt: syncNow.add(AppConstants.messageTtl),
      status: MessageStatus.pending,
    );

    _messages.add(outgoing);
    final isNetAvailable = _connectivityService.isNetworkAvailable;
    debugPrint('================================================================');
    debugPrint('[SQLITE DIAGNOSTIC] Outgoing Message Processing:');
    debugPrint('[SQLITE DIAGNOSTIC] Message ID: "$messageId", Content: "$trimmed"');
    debugPrint('[SQLITE DIAGNOSTIC] _connectivityService.isNetworkAvailable = $isNetAvailable');
    debugPrint('[SQLITE DIAGNOSTIC] _relayService.isConnected = ${_relayService.isConnected}');
    if (isNetAvailable) {
      debugPrint('[SQLITE DIAGNOSTIC] Action: Calling _messageDatabase.saveMessage(outgoing)...');
      unawaited(_messageDatabase.saveMessage(outgoing));
      developer.log('Outgoing message saved to local SQLite database: id=$messageId', name: 'ChatService');
    } else {
      debugPrint('[SQLITE DIAGNOSTIC] Action: SKIPPING saveMessage() because _connectivityService.isNetworkAvailable is FALSE!');
      developer.log('Internet OFF: Outgoing message NOT saved to database: id=$messageId', name: 'ChatService');
    }
    debugPrint('================================================================');
    _lastSendError = null;
    notifyListeners();

    // If device network is offline or WebSocket is not yet connected, enqueue locally
    if (!_connectivityService.isNetworkAvailable || !_relayService.isConnected) {
      _lastSendError = !_connectivityService.isNetworkAvailable
          ? 'No Network: Message queued locally'
          : 'Connecting to relay: Message queued locally';
      _offlineQueue.add(outgoing);
      notifyListeners();
      return false;
    }

    // Transmit over WebSocket relay
    final success = _relayService.sendMessage(
      id: messageId,
      text: trimmed,
    );

    if (success) {
      _lastSendError = null;
      notifyListeners();
      return true;
    } else {
      _lastSendError = 'Relay send failed: Queued locally';
      _offlineQueue.add(outgoing);
      notifyListeners();
      return false;
    }
  }

  /// Manually reconnects to the configured WebSocket relay.
  void reconnectRelay() {
    if (!_isStarted) return;
    _relayService.disconnect();
    _connectRelay();
  }

  /// Compatibility method retained for existing UI/tests. This no longer polls HTTP.
  Future<void> pollServerSync() async {
    _tickAndPruneExpired();
    _flushOfflineQueue();
  }

  /// Clears all messages manually (for demonstration reset).
  void clearAllMessages() {
    _messages.clear();
    _offlineQueue.clear();
    unawaited(_messageDatabase.clearAllMessages());
    developer.log('Cleared all messages from RAM and SQLite', name: 'ChatService');
    notifyListeners();
  }

  @visibleForTesting
  void addMessageForTesting(ChatMessage message) {
    _messages.add(message);
    if (_connectivityService.isNetworkAvailable) {
      unawaited(_messageDatabase.saveMessage(message));
    }
    _seenMessageIds.add(message.id);
    notifyListeners();
  }

  @visibleForTesting
  void enqueueOfflineMessageForTesting(ChatMessage message) {
    _offlineQueue.add(message);
    _seenMessageIds.add(message.id);
    notifyListeners();
  }

  @visibleForTesting
  void resetStateForTesting() {
    stop();
    // ignore: invalid_use_of_visible_for_testing_member
    _relayService.resetStateForTesting();
    _connectivityService.onConnectivityRestored = null;
    _connectivityService.onConnectivityLost = null;
    _messages.clear();
    _offlineQueue.clear();
    _seenMessageIds.clear();
    _presenceCount = 0;
    _presenceMembers = [];
    _lastSendError = null;
    _isStarted = false;
    _lastLifecycleState = AppLifecycleState.resumed;
    // ignore: invalid_use_of_visible_for_testing_member
    _messageDatabase.clearTestRecords();
  }

  @visibleForTesting
  void setPresenceForTesting(int count, List<String> members) {
    _presenceCount = count;
    _presenceMembers = List<String>.from(members);
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
