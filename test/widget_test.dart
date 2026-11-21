import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanish_class_network/main.dart';
import 'package:vanish_class_network/models/chat_message.dart';
import 'package:vanish_class_network/screens/chat_screen.dart';
import 'package:vanish_class_network/services/chat_service.dart';
import 'package:vanish_class_network/services/device_service.dart';
import 'package:vanish_class_network/utils/constants.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefKeyDeviceId: 'dev_test_12345',
      AppConstants.prefKeyDisplayName: 'Test Student',
    });
  });

  testWidgets('Join Class screen smoke test and validation',
      (WidgetTester tester) async {
    await tester.pumpWidget(const VanishClassNetworkApp());
    await tester.pumpAndSettle();

    // Verify App Title and room info are displayed
    expect(find.text(AppConstants.appTitle), findsOneWidget);
    expect(find.text('Join Class'), findsOneWidget);
    expect(find.text('Persistent Device ID'), findsOneWidget);

    // Clear display name field and tap Join Class to test validation
    final nameField = find.byType(TextFormField);
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, '');
    await tester.tap(find.text('Join Class'));
    await tester.pumpAndSettle();

    // Verify validation error is shown
    expect(
      find.text('Please enter your display name to join the class'),
      findsOneWidget,
    );
  });

  test('ChatMessage expiration and vanishing calculations', () {
    final now = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final message = ChatMessage(
      id: 'msg_1',
      senderId: 'dev_test',
      senderName: 'Alice',
      content: 'This will vanish in 30 seconds',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 30)),
      status: MessageStatus.delivered,
    );

    // At delivery time: 30 seconds remaining, not expired
    expect(message.isExpired(now), isFalse);
    expect(message.remainingSeconds(now), equals(30));

    // After 10 seconds: 20 seconds remaining
    final after10s = now.add(const Duration(seconds: 10));
    expect(message.isExpired(after10s), isFalse);
    expect(message.remainingSeconds(after10s), equals(20));

    // After 30 seconds: 0 seconds remaining, expired
    final after30s = now.add(const Duration(seconds: 30));
    expect(message.isExpired(after30s), isTrue);
    expect(message.remainingSeconds(after30s), equals(0));

    // After 35 seconds: expired
    final after35s = now.add(const Duration(seconds: 35));
    expect(message.isExpired(after35s), isTrue);
    expect(message.remainingSeconds(after35s), equals(0));
  });

  testWidgets(
    'ChatScreen renders Point 12 Presence bar with count and ordered members',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final deviceService = DeviceService();
      await deviceService.initialize();
      await deviceService.setDisplayName('Sawaira');

      chatService.resetStateForTesting();

      await tester.pumpWidget(
        const MaterialApp(
          home: ChatScreen(),
        ),
      );
      await tester.pump();

      // Initially count is 0, presence bar is hidden
      expect(find.text('3 students joined'), findsNothing);

      // Simulate presence event: Sawaira, Ali, Sara
      chatService.setPresenceForTesting(3, ['Sawaira', 'Ali', 'Sara']);
      await tester.pump();

      // Verify count is displayed
      expect(find.text('3 students joined'), findsOneWidget);

      // Verify members are displayed and local user is marked (You)
      expect(find.text('Sawaira (You)'), findsOneWidget);
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('Sara'), findsOneWidget);

      // Verify join order badges: 1, 2, 3
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // Simulate member leaving: Ali leaves
      chatService.setPresenceForTesting(2, ['Sawaira', 'Sara']);
      await tester.pump();

      // Verify dynamic update: 2 students joined, Ali is gone
      expect(find.text('2 students joined'), findsOneWidget);
      expect(find.text('3 students joined'), findsNothing);
      expect(find.text('Sawaira (You)'), findsOneWidget);
      expect(find.text('Ali'), findsNothing);
      expect(find.text('Sara'), findsOneWidget);

      chatService.stop();
    },
  );
}
