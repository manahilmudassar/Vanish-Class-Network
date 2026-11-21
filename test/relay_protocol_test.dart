import 'package:flutter_test/flutter_test.dart';
import 'package:vanish_class_network/models/chat_message.dart';
import 'package:vanish_class_network/services/chat_service.dart';
import 'package:vanish_class_network/services/time_sync_service.dart';
import 'package:vanish_class_network/services/websocket_relay_service.dart';
import 'package:vanish_class_network/utils/constants.dart';

void main() {
  final relay = WebSocketRelayService();
  final timeSync = TimeSyncService();

  setUp(() {
    relay.resetStateForTesting();
    timeSync.resetForTesting();
    relay.onWelcomeReceived = null;
    relay.onMessageReceived = null;
    relay.onPresenceReceived = null;
    relay.onErrorReceived = null;
  });

  tearDown(() {
    relay.resetStateForTesting();
    timeSync.resetForTesting();
    relay.onWelcomeReceived = null;
    relay.onMessageReceived = null;
    relay.onPresenceReceived = null;
    relay.onErrorReceived = null;
  });

  test('WELCOME validates protocol and synchronizes relay clock', () {
    var welcomed = false;
    relay.onWelcomeReceived = () => welcomed = true;

    final serverTime = DateTime.now().toUtc().millisecondsSinceEpoch + 2500;
    relay.simulateIncomingData(
      '{"type":"welcome","protocol":1,"server_time":$serverTime}',
    );

    expect(welcomed, isTrue);
    expect(relay.isConnected, isTrue);
    expect(timeSync.hasSynced, isTrue);
    expect(timeSync.serverClockOffset.inMilliseconds, greaterThanOrEqualTo(2000));
    expect(timeSync.serverClockOffset.inMilliseconds, lessThanOrEqualTo(3000));
    expect(relay.isPingTimerActive, isTrue);
  });

  test('Incoming message requires server timestamps and exact 30-second TTL', () {
    String? receivedId;
    String? errorCode;
    relay.onMessageReceived = (id, sender, text, sentAt, expiresAt) {
      receivedId = id;
    };
    relay.onErrorReceived = (code, message) => errorCode = code;
    relay.simulateIncomingData(
      '{"type":"welcome","protocol":1,"server_time":1794839291139}',
    );

    relay.simulateIncomingData(
      '{"type":"message","id":"m1","sender":"Ayesha","text":"Hello","sent_at":100000,"expires_at":130000}',
    );
    expect(receivedId, 'm1');
    expect(errorCode, isNull);

    relay.simulateIncomingData(
      '{"type":"message","id":"m2","sender":"Ayesha","text":"No timestamps"}',
    );
    expect(receivedId, 'm1');
    expect(errorCode, 'bad_message');
  });

  test('Protocol message parser rejects missing server timestamps', () {
    final parsed = ChatMessage.fromProtocolJson({
      'id': 'm1',
      'sender': 'Ayesha',
      'text': 'Hello',
    });
    expect(parsed, isNull);
  });

  test('Protocol message parser uses relay expiry timestamp', () {
    final sentAt = DateTime.utc(2026, 11, 17).millisecondsSinceEpoch;
    final parsed = ChatMessage.fromProtocolJson({
      'id': 'm1',
      'sender': 'Ayesha',
      'text': 'Hello',
      'sent_at': sentAt,
      'expires_at': sentAt + AppConstants.messageTtl.inMilliseconds,
    });

    expect(parsed, isNotNull);
    expect(parsed!.expiresAt.millisecondsSinceEpoch,
        sentAt + AppConstants.messageTtl.inMilliseconds);
    expect(parsed.senderId, 'peer_m1');
  });

  test('Point 12 PRESENCE validates frame and preserves relay member order', () {
    int? receivedCount;
    List<String>? receivedMembers;
    relay.onPresenceReceived = (count, members) {
      receivedCount = count;
      receivedMembers = members;
    };

    relay.simulateIncomingData(
      '{"type":"presence","count":3,"members":["Sawaira","Ali","Sara"]}',
    );

    expect(receivedCount, equals(3));
    expect(receivedMembers, equals(['Sawaira', 'Ali', 'Sara']));
    expect(receivedMembers![0], equals('Sawaira'));
    expect(receivedMembers![1], equals('Ali'));
    expect(receivedMembers![2], equals('Sara'));
  });

  test('Point 12 PRESENCE updates dynamically when someone leaves', () {
    int? receivedCount;
    List<String>? receivedMembers;
    relay.onPresenceReceived = (count, members) {
      receivedCount = count;
      receivedMembers = members;
    };

    // Initial 3 members
    relay.simulateIncomingData(
      '{"type":"presence","count":3,"members":["Sawaira","Ali","Sara"]}',
    );
    expect(receivedCount, equals(3));

    // Ali leaves -> updated to 2 members in join order
    relay.simulateIncomingData(
      '{"type":"presence","count":2,"members":["Sawaira","Sara"]}',
    );
    expect(receivedCount, equals(2));
    expect(receivedMembers, equals(['Sawaira', 'Sara']));
  });

  test('Point 12 PRESENCE rejects malformed presence frames', () {
    String? errorCode;
    relay.onErrorReceived = (code, message) => errorCode = code;

    relay.simulateIncomingData(
      '{"type":"presence","count":"invalid","members":"not_a_list"}',
    );
    expect(errorCode, equals('bad_message'));
  });

  test('Point 12 PRESENCE updates ChatService state and preserves order', () {
    final chatService = ChatService();
    chatService.resetStateForTesting();

    expect(chatService.presenceCount, equals(0));
    expect(chatService.presenceMembers, isEmpty);

    chatService.setPresenceForTesting(3, ['Sawaira', 'Ali', 'Sara']);

    expect(chatService.presenceCount, equals(3));
    expect(chatService.presenceMembers, equals(['Sawaira', 'Ali', 'Sara']));
    expect(chatService.presenceMembers[0], equals('Sawaira'));
    expect(chatService.presenceMembers[1], equals('Ali'));
    expect(chatService.presenceMembers[2], equals('Sara'));

    chatService.stop();
  });
}
