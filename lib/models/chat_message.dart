import 'sync_record.dart';
import '../utils/constants.dart';

enum MessageStatus {
  pending,
  delivered,
  expired,
  failed,
}

class ChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final String room;
  final DateTime createdAt;
  final DateTime? deliveredAt;
  final DateTime expiresAt;
  final MessageStatus status;
  final int? deliveryCount;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    this.room = AppConstants.defaultRoomName,
    required this.createdAt,
    this.deliveredAt,
    required this.expiresAt,
    this.status = MessageStatus.delivered,
    this.deliveryCount,
  });

  /// Factory to create a newly composed outgoing message.
  factory ChatMessage.createOutgoing({
    required String id,
    required String senderId,
    required String senderName,
    required String content,
    required DateTime currentSyncTime,
    String room = AppConstants.defaultRoomName,
  }) {
    final now = currentSyncTime;
    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      content: content,
      room: room,
      createdAt: now,
      deliveredAt: null,
      expiresAt: now.add(AppConstants.messageTtl),
      status: MessageStatus.pending,
    );
  }

  /// Whether this message has expired according to synchronized server time.
  bool isExpired(DateTime currentSyncTime) {
    return currentSyncTime.isAfter(expiresAt) ||
        currentSyncTime.isAtSameMomentAs(expiresAt);
  }

  /// Remaining duration until the message vanishes.
  /// 
  /// Conforms to Vanish Relay Protocol v1 Section 9:
  /// Countdown = (expires_at - offset) - phone_time
  /// where currentSyncTime = phone_time + offset.
  Duration remainingDuration(DateTime currentSyncTime) {
    if (isExpired(currentSyncTime)) return Duration.zero;
    return expiresAt.difference(currentSyncTime);
  }

  /// Remaining seconds (0..30)
  int remainingSeconds(DateTime currentSyncTime) {
    if (isExpired(currentSyncTime)) return 0;
    final remainingMs =
        expiresAt.millisecondsSinceEpoch - currentSyncTime.millisecondsSinceEpoch;
    if (remainingMs <= 0) return 0;
    final seconds = (remainingMs / 1000).ceil();
    if (seconds > AppConstants.messageTtl.inSeconds) {
      return AppConstants.messageTtl.inSeconds;
    }
    return seconds;
  }

  /// Fraction of remaining lifespan (1.0 = fresh, 0.0 = vanished)
  double remainingFraction(DateTime currentSyncTime) {
    final totalMs = AppConstants.messageTtl.inMilliseconds;
    final remainingMs = remainingDuration(currentSyncTime).inMilliseconds;
    if (remainingMs <= 0) return 0.0;
    if (remainingMs >= totalMs) return 1.0;
    return remainingMs / totalMs;
  }

  ChatMessage copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? content,
    String? room,
    DateTime? createdAt,
    DateTime? deliveredAt,
    DateTime? expiresAt,
    MessageStatus? status,
    int? deliveryCount,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      content: content ?? this.content,
      room: room ?? this.room,
      createdAt: createdAt ?? this.createdAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      expiresAt: expiresAt ?? this.expiresAt,
      status: status ?? this.status,
      deliveryCount: deliveryCount ?? this.deliveryCount,
    );
  }

  /// Converts this message to the Vanish Relay Protocol v1 SEND format:
  /// `{"type":"message","id":"<unique id>","sender":"<display name>","text":"<message>"}`
  Map<String, dynamic> toProtocolSendJson() => {
        'type': 'message',
        'id': id,
        'sender': senderName,
        'text': content,
      };

  /// Parses an incoming message from the Vanish Relay Protocol v1:
  /// {"type":"message","id":"...","sender":"...","text":"...","sent_at":1794839366594,"expires_at":1794839396594}
  static ChatMessage? fromProtocolJson(Map<String, dynamic> json) {
    final id = json['id'];
    final sender = json['sender'];
    final text = json['text'];
    final sentAtMs = json['sent_at'];
    final expiresAtMs = json['expires_at'];

    if (id is! String || id.isEmpty ||
        sender is! String || sender.isEmpty || sender.length > 30 ||
        text is! String || text.isEmpty || text.length > 500 ||
        sentAtMs is! int || expiresAtMs is! int ||
        expiresAtMs - sentAtMs != AppConstants.messageTtl.inMilliseconds) {
      return null;
    }

    final sentAt = DateTime.fromMillisecondsSinceEpoch(sentAtMs, isUtc: true);
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true);

    // The protocol has no sender device ID. Own messages are recognized by
    // matching the pending outgoing message ID in ChatService, not by name.
    return ChatMessage(
      id: id,
      senderId: 'peer_$id',
      senderName: sender,
      content: text,
      createdAt: sentAt,
      deliveredAt: sentAt,
      expiresAt: expiresAt,
      status: MessageStatus.delivered,
    );
  }

  /// Converts this chat message into a SyncRecord for POST /sync/push (Field Sync legacy)
  SyncRecord toSyncRecord() {
    return SyncRecord(
      recordId: id,
      type: 'chat_message',
      timestamp: createdAt.millisecondsSinceEpoch,
      data: {
        'id': id,
        'sender_id': senderId,
        'sender_name': senderName,
        'content': content,
        'room': room,
        'created_at': createdAt.toIso8601String(),
        'delivered_at': deliveredAt?.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
      },
    );
  }

  /// Parses a ChatMessage from a SyncRecord received via GET /sync/pull (Field Sync legacy)
  static ChatMessage? fromSyncRecord(
    SyncRecord record, {
    required DateTime serverSyncTime,
  }) {
    if (record.type != 'chat_message') return null;

    final data = record.data;
    final id = data['id']?.toString() ?? record.recordId;
    if (id.isEmpty) return null;

    final senderId = data['sender_id']?.toString() ?? 'unknown_device';
    final senderName = data['sender_name']?.toString() ?? 'Anonymous';
    final content = data['content']?.toString() ?? '';
    final room = data['room']?.toString() ?? AppConstants.defaultRoomName;

    final createdAtStr = data['created_at']?.toString();
    final createdAt = createdAtStr != null
        ? (DateTime.tryParse(createdAtStr)?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(record.timestamp, isUtc: true))
        : DateTime.fromMillisecondsSinceEpoch(record.timestamp, isUtc: true);

    final expiresAtStr = data['expires_at']?.toString();
    DateTime expiresAt;
    if (expiresAtStr != null && DateTime.tryParse(expiresAtStr) != null) {
      expiresAt = DateTime.parse(expiresAtStr).toUtc();
    } else {
      expiresAt = serverSyncTime.add(AppConstants.messageTtl);
    }

    final deliveredAtStr = data['delivered_at']?.toString();
    final deliveredAt = deliveredAtStr != null
        ? DateTime.tryParse(deliveredAtStr)?.toUtc()
        : serverSyncTime;

    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      content: content,
      room: room,
      createdAt: createdAt,
      deliveredAt: deliveredAt,
      expiresAt: expiresAt,
      status: MessageStatus.delivered,
    );
  }
}
