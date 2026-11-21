import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanish_class_network/models/chat_message.dart';
import 'package:vanish_class_network/services/chat_service.dart';
import 'package:vanish_class_network/services/time_sync_service.dart';
import 'package:vanish_class_network/utils/constants.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefKeyDeviceId: 'dev_test_device',
      AppConstants.prefKeyDisplayName: 'Test Student',
    });
    TimeSyncService().resetForTesting();
    ChatService().resetStateForTesting();
  });

  tearDown(() {
    ChatService().stop();
    TimeSyncService().resetForTesting();
  });

  testWidgets(
    'Case 1, 2 & 5: Message with 20s remaining when paused resumes still valid with recalculated remaining time',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final timeService = TimeSyncService();

      chatService.start();

      final now = timeService.synchronizedNow;
      // Message created 10 seconds ago, with exactly 20 seconds remaining
      final msg = ChatMessage(
        id: 'msg_20s',
        senderId: 'dev_peer',
        senderName: 'Peer Student',
        content: 'Valid message across lifecycle',
        createdAt: now.subtract(const Duration(seconds: 10)),
        expiresAt: now.add(const Duration(seconds: 20)),
        status: MessageStatus.delivered,
      );

      chatService.addMessageForTesting(msg);

      // Verify baseline remaining time
      expect(chatService.messages.length, equals(1));
      expect(msg.remainingSeconds(timeService.synchronizedNow), equals(20));

      // App enters background
      chatService.handleAppLifecycleState(AppLifecycleState.paused);
      expect(chatService.isCountdownTimerActive, isFalse);

      // Controlled time advance: 5 seconds elapse in background
      timeService.setClockOffsetForTesting(const Duration(seconds: 5));

      // App returns to foreground
      chatService.handleAppLifecycleState(AppLifecycleState.resumed);

      // Verify: Message remains visible and unexpired
      expect(chatService.messages.length, equals(1));
      final surviving = chatService.messages.first;
      expect(surviving.id, equals('msg_20s'));
      // Recalculated remaining time is now 15 seconds (20s - 5s)
      expect(surviving.remainingSeconds(timeService.synchronizedNow), equals(15));
      expect(surviving.isExpired(timeService.synchronizedNow), isFalse);

      // Clean up timers before widget invariant checks
      chatService.stop();
    },
  );

  testWidgets(
    'Case 3: App resumes after the message expiry time has passed (message immediately removed)',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final timeService = TimeSyncService();

      chatService.start();

      final now = timeService.synchronizedNow;
      // Message created 10 seconds ago, expiring in 20 seconds
      final msg = ChatMessage(
        id: 'msg_to_expire',
        senderId: 'dev_peer',
        senderName: 'Peer Student',
        content: 'This message will expire while in background',
        createdAt: now.subtract(const Duration(seconds: 10)),
        expiresAt: now.add(const Duration(seconds: 20)),
        status: MessageStatus.delivered,
      );

      chatService.addMessageForTesting(msg);
      expect(chatService.messages.length, equals(1));

      // App enters background
      chatService.handleAppLifecycleState(AppLifecycleState.paused);

      // Controlled time advance: 25 seconds elapse (surpasses the 20s remaining)
      timeService.setClockOffsetForTesting(const Duration(seconds: 25));

      // App returns to foreground
      chatService.handleAppLifecycleState(AppLifecycleState.resumed);

      // Verify: Expired message is immediately removed from the active message list
      expect(chatService.messages.isEmpty, isTrue);

      // Clean up timers before widget invariant checks
      chatService.stop();
    },
  );

  testWidgets(
    'Case 4: An expired offline queued message is discarded immediately after resume',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final timeService = TimeSyncService();

      chatService.start();

      final now = timeService.synchronizedNow;
      // Offline queued message with only 10 seconds remaining
      final queuedMsg = ChatMessage(
        id: 'queued_msg_to_expire',
        senderId: 'dev_my_phone',
        senderName: 'Myself',
        content: 'Offline queued message expiring soon',
        createdAt: now.subtract(const Duration(seconds: 20)),
        expiresAt: now.add(const Duration(seconds: 10)),
        status: MessageStatus.pending,
      );

      chatService.enqueueOfflineMessageForTesting(queuedMsg);
      expect(chatService.offlineQueue.length, equals(1));

      // App enters background
      chatService.handleAppLifecycleState(AppLifecycleState.paused);

      // Controlled time advance: 15 seconds elapse in background
      timeService.setClockOffsetForTesting(const Duration(seconds: 15));

      // App returns to foreground
      chatService.handleAppLifecycleState(AppLifecycleState.resumed);

      // Verify: Expired offline queued message is purged and never sent
      expect(chatService.offlineQueue.isEmpty, isTrue);

      // Clean up timers before widget invariant checks
      chatService.stop();
    },
  );

  testWidgets(
    'Case 6: Lifecycle observer registration and disposal do not create duplicate callbacks or timers',
    (WidgetTester tester) async {
      final chatService = ChatService();

      expect(chatService.isObserverRegistered, isFalse);
      expect(chatService.isStarted, isFalse);

      // First start
      chatService.start();
      expect(chatService.isStarted, isTrue);
      expect(chatService.isObserverRegistered, isTrue);
      expect(chatService.isCountdownTimerActive, isTrue);
      expect(chatService.isSyncTimerActive, isTrue);

      // Redundant start call must be safe and idempotent
      chatService.start();
      expect(chatService.isObserverRegistered, isTrue);
      expect(chatService.isCountdownTimerActive, isTrue);
      expect(chatService.isSyncTimerActive, isTrue);

      // Stop call
      chatService.stop();
      expect(chatService.isStarted, isFalse);
      expect(chatService.isObserverRegistered, isFalse);
      expect(chatService.isCountdownTimerActive, isFalse);
      expect(chatService.isSyncTimerActive, isFalse);

      // Redundant stop call must be safe and idempotent
      chatService.stop();
      expect(chatService.isObserverRegistered, isFalse);
      expect(chatService.isCountdownTimerActive, isFalse);
      expect(chatService.isSyncTimerActive, isFalse);
    },
  );
}
