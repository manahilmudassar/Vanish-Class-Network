class AppConstants {
  static const String appTitle = 'Vanish Class Network';
  static const String defaultRoomName = 'Class Room';
  
  /// Relay message lifespan from sent_at: exactly 30 seconds
  static const Duration messageTtl = Duration(seconds: 30);

  /// Proposed Vanish Relay Protocol v1 address
  static const String defaultWebSocketUrl =
      'wss://vanish-relay-sawaira.bonto.page/ws';

  /// Protocol version as per PROTOCOL.md
  static const int protocolVersion = 1;

  /// Heartbeat ping interval: exactly 15 seconds
  static const Duration pingInterval = Duration(seconds: 15);

  /// Heartbeat timeout if no pong received: 30 seconds
  static const Duration pongTimeout = Duration(seconds: 30);

  /// Reconnection backoff steps in seconds: 1, 2, 4, then 8 (PROTOCOL.md Section 7)
  static const List<int> reconnectDelaysSeconds = [1, 2, 4, 8];

  /// Protocol validation constraints
  static const int minDisplayNameLength = 1;
  static const int maxDisplayNameLength = 30;
  static const int minMessageLength = 1;
  static const int maxMessageLength = 500;
  
  /// Default HTTP server URL for Android Emulator (retained for Field Sync)
  static const String defaultServerUrl = 'http://10.0.2.2:8000';
  
  /// Alternative HTTP server URL for desktop/web testing
  static const String localhostServerUrl = 'http://127.0.0.1:8000';

  /// Sync polling interval (for legacy Field Sync HTTP fallback)
  static const Duration syncPollInterval = Duration(seconds: 3);

  /// Message countdown UI refresh rate (for smooth second countdowns)
  static const Duration countdownTickInterval = Duration(milliseconds: 250);

  // Storage keys for persistent preferences
  static const String prefKeyDeviceId = 'vanish_device_id';
  static const String prefKeyDisplayName = 'vanish_display_name';
  static const String prefKeyServerUrl = 'vanish_server_url';
  static const String prefKeyWebSocketUrl = 'vanish_ws_url';
}
