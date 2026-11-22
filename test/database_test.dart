import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanish_class_network/models/chat_message.dart';
import 'package:vanish_class_network/services/chat_service.dart';
import 'package:vanish_class_network/services/connectivity_service.dart';
import 'package:vanish_class_network/services/message_database_service.dart';
import 'package:vanish_class_network/services/time_sync_service.dart';
import 'package:vanish_class_network/services/websocket_relay_service.dart';
import 'package:vanish_class_network/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefKeyDeviceId: 'dev_connectivity_save_test',
      AppConstants.prefKeyDisplayName: 'Test Student',
    });
    TimeSyncService().resetForTesting();
    ChatService().resetStateForTesting();
    ConnectivityService().resetForTesting();
    WebSocketRelayService().resetStateForTesting();
  });

  tearDown(() {
    ChatService().stop();
    ConnectivityService().resetForTesting();
    WebSocketRelayService().resetStateForTesting();
    TimeSyncService().resetForTesting();
  });

  group('SQLite Message Mapping and 30-Second Expiry Tests', () {
    test('ChatMessage.toDbMap serializes all 10 SQLite columns accurately', () {
      final now = DateTime.utc(2026, 11, 22, 10, 0, 0);
      final delivered = DateTime.utc(2026, 11, 22, 10, 0, 1);
      final expires = now.add(AppConstants.messageTtl);

      final message = ChatMessage(
        id: 'msg_test_001',
        senderId: 'dev_001',
        senderName: 'Student Alpha',
        content: 'Hello everyone in class!',
        room: 'Math Class',
        createdAt: now,
        deliveredAt: delivered,
        expiresAt: expires,
        status: MessageStatus.delivered,
        deliveryCount: 3,
      );

      final map = message.toDbMap();

      expect(map['id'], equals('msg_test_001'));
      expect(map['sender_id'], equals('dev_001'));
      expect(map['sender_name'], equals('Student Alpha'));
      expect(map['content'], equals('Hello everyone in class!'));
      expect(map['room'], equals('Math Class'));
      expect(map['created_at'], equals(now.millisecondsSinceEpoch));
      expect(map['delivered_at'], equals(delivered.millisecondsSinceEpoch));
      expect(map['expires_at'], equals(expires.millisecondsSinceEpoch));
      expect(map['status'], equals('delivered'));
      expect(map['delivery_count'], equals(3));
    });

    test('ChatMessage.fromDbMap deserializes all 10 columns and preserves exact timestamps', () {
      final createdMs = 1719959040000;
      final deliveredMs = 1719959041000;
      final expiresMs = 1719959070000; // exactly 30 seconds after createdMs

      final map = <String, dynamic>{
        'id': 'a1b2c3d4',
        'sender_id': 'device_001',
        'sender_name': 'Student',
        'content': 'Hello everyone',
        'room': 'Math Class',
        'created_at': createdMs,
        'delivered_at': deliveredMs,
        'expires_at': expiresMs,
        'status': 'delivered',
        'delivery_count': 1,
      };

      final message = ChatMessage.fromDbMap(map);

      expect(message.id, equals('a1b2c3d4'));
      expect(message.senderId, equals('device_001'));
      expect(message.senderName, equals('Student'));
      expect(message.content, equals('Hello everyone'));
      expect(message.room, equals('Math Class'));
      expect(message.createdAt.millisecondsSinceEpoch, equals(createdMs));
      expect(message.deliveredAt?.millisecondsSinceEpoch, equals(deliveredMs));
      expect(message.expiresAt.millisecondsSinceEpoch, equals(expiresMs));
      expect(message.status, equals(MessageStatus.delivered));
      expect(message.deliveryCount, equals(1));
    });

    test('Exact original relay expiry condition: expires_at <= synchronizedNow', () {
      final sentAtMs = 1719959040000;
      final expiresAtMs = sentAtMs + 30000; // 30 seconds
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true);

      final message = ChatMessage(
        id: 'msg_expiry_check',
        senderId: 'dev_002',
        senderName: 'Student B',
        content: 'Hi Manahil!',
        room: 'Math Class',
        createdAt: DateTime.fromMillisecondsSinceEpoch(sentAtMs, isUtc: true),
        deliveredAt: DateTime.fromMillisecondsSinceEpoch(sentAtMs + 1000, isUtc: true),
        expiresAt: expiresAt,
        status: MessageStatus.delivered,
        deliveryCount: 1,
      );

      // 1. Before expiry: at 29 seconds, remaining is 1s, not expired
      final timeAt29s = DateTime.fromMillisecondsSinceEpoch(sentAtMs + 29000, isUtc: true);
      expect(message.isExpired(timeAt29s), isFalse);
      expect(message.remainingSeconds(timeAt29s), equals(1));

      // 2. Exactly at 30 seconds: expires_at <= synchronizedNow is true!
      final timeAt30s = DateTime.fromMillisecondsSinceEpoch(expiresAtMs, isUtc: true);
      expect(message.isExpired(timeAt30s), isTrue);
      expect(message.remainingSeconds(timeAt30s), equals(0));

      // 3. After 30 seconds: expired
      final timeAt31s = DateTime.fromMillisecondsSinceEpoch(expiresAtMs + 1000, isUtc: true);
      expect(message.isExpired(timeAt31s), isTrue);
      expect(message.remainingSeconds(timeAt31s), equals(0));
    });

    test('Multiple messages expire independently based on their own original expires_at', () {
      final baseTime = DateTime.utc(2026, 11, 22, 10, 0, 0);

      // Message A sent at t=0s, expires at t=30s
      final msgA = ChatMessage(
        id: 'msg_A',
        senderId: 'dev_1',
        senderName: 'Alice',
        content: 'First message',
        createdAt: baseTime,
        expiresAt: baseTime.add(const Duration(seconds: 30)),
        status: MessageStatus.delivered,
      );

      // Message B sent at t=15s, expires at t=45s
      final msgB = ChatMessage(
        id: 'msg_B',
        senderId: 'dev_2',
        senderName: 'Bob',
        content: 'Second message',
        createdAt: baseTime.add(const Duration(seconds: 15)),
        expiresAt: baseTime.add(const Duration(seconds: 45)),
        status: MessageStatus.delivered,
      );

      // At t=30s: msgA has expired, but msgB still has 15s remaining
      final timeAt30s = baseTime.add(const Duration(seconds: 30));
      expect(msgA.isExpired(timeAt30s), isTrue);
      expect(msgB.isExpired(timeAt30s), isFalse);
      expect(msgB.remainingSeconds(timeAt30s), equals(15));

      // At t=45s: msgB also expires
      final timeAt45s = baseTime.add(const Duration(seconds: 45));
      expect(msgB.isExpired(timeAt45s), isTrue);
    });

    test('MessageDatabaseService safely captures errors without crashing caller', () async {
      final service = MessageDatabaseService.instance;

      final dummyMsg = ChatMessage(
        id: 'dummy_msg',
        senderId: 'dev_dummy',
        senderName: 'Tester',
        content: 'Testing error resilience',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 30)),
      );

      final saveResult = await service.saveMessage(dummyMsg);
      expect(saveResult, isFalse);

      final deleteResult = await service.deleteMessage('dummy_msg');
      expect(deleteResult, isFalse);

      final pruneResult = await service.deleteExpiredMessages(DateTime.now().toUtc());
      expect(pruneResult, equals(0));

      final activeMessages = await service.getActiveMessages(DateTime.now().toUtc());
      expect(activeMessages, isEmpty);
    });
  });

  group('Internet Connectivity Conditions for Database Saving', () {
    test('Condition 1: Internet ON + Server ON saves both outgoing and incoming messages', () async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final relay = WebSocketRelayService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(true);
      relay.setStatusForTesting(WebSocketConnectionStatus.connected, joined: true);
      db.clearTestRecords();

      // 1. Send outgoing message
      await chatService.sendMessage('Hello outgoing when both ON');
      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Hello outgoing when both ON'),
        isTrue,
        reason: 'Outgoing message must be saved when Internet is ON and Server is ON',
      );

      // 2. Receive incoming peer message
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      relay.simulateIncomingData(jsonEncode({
        'type': 'message',
        'id': 'peer_incoming_c1',
        'sender': 'PeerAlpha',
        'text': 'Incoming peer message when both ON',
        'sent_at': nowMs,
        'expires_at': nowMs + 30000,
      }));

      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Incoming peer message when both ON'),
        isTrue,
        reason: 'Incoming message must be saved when Internet is ON and Server is ON',
      );
      chatService.stop();
    });

    test('Condition 2: Internet OFF + Server ON does NOT save outgoing or incoming messages', () async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final relay = WebSocketRelayService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(false);
      relay.setStatusForTesting(WebSocketConnectionStatus.connected, joined: true);
      db.clearTestRecords();

      // 1. Attempt sending outgoing message
      await chatService.sendMessage('Hello outgoing when Internet OFF');
      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Hello outgoing when Internet OFF'),
        isFalse,
        reason: 'Outgoing message must NOT be saved to SQLite when Internet is OFF',
      );

      // 2. Simulated incoming message
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      relay.simulateIncomingData(jsonEncode({
        'type': 'message',
        'id': 'peer_incoming_c2',
        'sender': 'PeerBeta',
        'text': 'Incoming message when Internet OFF',
        'sent_at': nowMs,
        'expires_at': nowMs + 30000,
      }));

      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Incoming message when Internet OFF'),
        isFalse,
        reason: 'Incoming message must NOT be saved to SQLite when Internet is OFF',
      );
      chatService.stop();
    });

    test('Condition 3: Internet ON + Server OFF saves outgoing messages locally in SQLite', () async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final relay = WebSocketRelayService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(true);
      relay.setStatusForTesting(WebSocketConnectionStatus.disconnected, joined: false);
      db.clearTestRecords();

      // Outgoing message when Internet ON but Server OFF
      await chatService.sendMessage('Hello local storage when Server OFF');
      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Hello local storage when Server OFF'),
        isTrue,
        reason: 'Outgoing message must be saved locally in SQLite when Internet is ON even if Server is OFF',
      );
      expect(
        chatService.offlineQueue.any((m) => m.content == 'Hello local storage when Server OFF'),
        isTrue,
        reason: 'Message must also be queued locally when server is unreachable',
      );

      chatService.stop();
    });

    test('Condition 4: Internet OFF + Server OFF does NOT save outgoing messages to SQLite', () async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final relay = WebSocketRelayService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(false);
      relay.setStatusForTesting(WebSocketConnectionStatus.disconnected, joined: false);
      db.clearTestRecords();

      // Outgoing message when Internet OFF and Server OFF
      await chatService.sendMessage('Hello message when both OFF');
      expect(
        db.savedMessagesForTesting.any((m) => m.content == 'Hello message when both OFF'),
        isFalse,
        reason: 'Outgoing message must NOT be saved to SQLite when Internet is OFF and Server is OFF',
      );
      expect(
        chatService.offlineQueue.any((m) => m.content == 'Hello message when both OFF'),
        isTrue,
        reason: 'Message is placed in offlineQueue in RAM without being saved to SQLite',
      );

      chatService.stop();
    });

    test('Recovery: When Internet transitions from OFF to ON, newly sent messages are saved', () async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(false);
      db.clearTestRecords();

      // Step 1: Internet OFF - sending does not save to SQLite
      await chatService.sendMessage('Sent during offline');
      expect(db.savedMessagesForTesting.any((m) => m.content == 'Sent during offline'), isFalse);

      // Step 2: Internet restored
      connectivity.setNetworkAvailableForTesting(true);

      // Step 3: Sending new message now saves to SQLite
      await chatService.sendMessage('Sent after online restored');
      expect(db.savedMessagesForTesting.any((m) => m.content == 'Sent after online restored'), isTrue);

      chatService.stop();
    });

    testWidgets('Simultaneous UI and SQLite deletion: message vanishes from chat and database together at 30s', (WidgetTester tester) async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();
      final timeService = TimeSyncService();
      final db = MessageDatabaseService.instance;

      chatService.start();
      connectivity.setNetworkAvailableForTesting(true);
      db.clearTestRecords();

      final now = timeService.synchronizedNow;
      final msg = ChatMessage(
        id: 'msg_simultaneous_vanish',
        senderId: 'dev_user',
        senderName: 'Student A',
        content: 'Vanish test message',
        createdAt: now,
        expiresAt: now.add(const Duration(seconds: 30)),
        status: MessageStatus.delivered,
      );

      chatService.addMessageForTesting(msg);

      // 1. Before expiry: Message is present in both visible chat UI and SQLite
      expect(chatService.messages.any((m) => m.id == 'msg_simultaneous_vanish'), isTrue);
      expect(db.savedMessagesForTesting.any((m) => m.id == 'msg_simultaneous_vanish'), isTrue);
      expect(db.deletedMessageIdsForTesting.contains('msg_simultaneous_vanish'), isFalse);

      // Advance time by 30 seconds to reach expiry
      timeService.setClockOffsetForTesting(const Duration(seconds: 30));

      // Pump 250ms to trigger the countdown tick
      await tester.pump(const Duration(milliseconds: 250));

      // 2. At expiry: Message has vanished from both chat UI and SQLite simultaneously
      expect(
        chatService.messages.any((m) => m.id == 'msg_simultaneous_vanish'),
        isFalse,
        reason: 'Message must be removed from chat screen',
      );
      expect(
        db.savedMessagesForTesting.any((m) => m.id == 'msg_simultaneous_vanish'),
        isFalse,
        reason: 'Message must be removed from active SQLite database records',
      );
      expect(
        db.deletedMessageIdsForTesting.contains('msg_simultaneous_vanish'),
        isTrue,
        reason: 'SQLite deleteMessage must be executed at the exact same moment',
      );

      chatService.stop();
    });
  });
}
