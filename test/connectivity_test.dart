import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vanish_class_network/services/chat_service.dart';
import 'package:vanish_class_network/services/connectivity_service.dart';
import 'package:vanish_class_network/services/websocket_relay_service.dart';
import 'package:vanish_class_network/services/time_sync_service.dart';
import 'package:vanish_class_network/utils/constants.dart';
import 'package:vanish_class_network/widgets/connection_status_badge.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefKeyDeviceId: 'dev_connectivity_test',
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
    TimeSyncService().resetForTesting();
  });

  testWidgets(
    'Requirement 1: Network unavailable displays No Network status',
    (WidgetTester tester) async {
      final connectivity = ConnectivityService();
      connectivity.setNetworkAvailableForTesting(false);

      expect(connectivity.isNetworkAvailable, isFalse);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConnectionStatusBadge(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('No Network'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off_outlined), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    },
  );

  test(
    'Requirement 2: Network becomes available triggers reconnection callback',
    () {
      final connectivity = ConnectivityService();
      connectivity.setNetworkAvailableForTesting(false);

      bool restoredCalled = false;
      connectivity.onConnectivityRestored = () {
        restoredCalled = true;
      };

      // Network transitions to available
      connectivity.setNetworkAvailableForTesting(true);

      expect(restoredCalled, isTrue);
      expect(connectivity.isNetworkAvailable, isTrue);
    },
  );

  testWidgets(
    'Requirement 3: Network available but server unreachable shows Server Offline (NOT Connected)',
    (WidgetTester tester) async {
      final connectivity = ConnectivityService();
      final relayService = WebSocketRelayService();

      // Device has Wi-Fi / network connection
      connectivity.setNetworkAvailableForTesting(true);
      // But server health check failed / server is offline
      relayService.setStatusForTesting(WebSocketConnectionStatus.error);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConnectionStatusBadge(),
          ),
        ),
      );
      await tester.pump();

      // Must NOT claim Connected just because Wi-Fi is active
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Server Offline'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    },
  );

  testWidgets(
    'Requirement 4: Network available and server reachable shows Connected',
    (WidgetTester tester) async {
      final connectivity = ConnectivityService();
      final relayService = WebSocketRelayService();

      // Device has network connection AND server is verified reachable
      connectivity.setNetworkAvailableForTesting(true);
      relayService.setStatusForTesting(
        WebSocketConnectionStatus.connected,
        joined: true,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConnectionStatusBadge(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Connected'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_done), findsOneWidget);
      expect(find.text('No Network'), findsNothing);
      expect(find.text('Server Offline'), findsNothing);
    },
  );

  testWidgets(
    'Requirement 5: Reconnection does not create duplicate polling timers',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();

      chatService.start();

      expect(chatService.isCountdownTimerActive, isTrue);
      expect(chatService.isSyncTimerActive, isTrue);

      // Simulate network dropping and reconnecting repeatedly
      connectivity.setNetworkAvailableForTesting(false);
      connectivity.setNetworkAvailableForTesting(true);
      connectivity.setNetworkAvailableForTesting(false);
      connectivity.setNetworkAvailableForTesting(true);

      // Timers should still be cleanly active without duplicates or exceptions
      expect(chatService.isCountdownTimerActive, isTrue);
      expect(chatService.isSyncTimerActive, isTrue);

      // Clean stop
      chatService.stop();
      expect(chatService.isCountdownTimerActive, isFalse);
      expect(chatService.isSyncTimerActive, isFalse);
    },
  );

  test(
    'Requirement 6: Connectivity listener is properly disposed',
    () async {
      final connectivity = ConnectivityService();

      await connectivity.initialize();
      expect(connectivity.isListening, isTrue);

      connectivity.disposeService();
      expect(connectivity.isListening, isFalse);
    },
  );

  testWidgets(
    'Requirement 7: Sending message when network unavailable enqueues directly into offline queue',
    (WidgetTester tester) async {
      final chatService = ChatService();
      final connectivity = ConnectivityService();

      chatService.start();
      connectivity.setNetworkAvailableForTesting(false);

      final result = await chatService.sendMessage('Test offline message');

      // Message cannot be sent over network, so returns false and enqueues locally
      expect(result, isFalse);
      expect(chatService.offlineQueue.length, equals(1));
      expect(chatService.offlineQueue.first.content, equals('Test offline message'));

      chatService.stop();
    },
  );
}
