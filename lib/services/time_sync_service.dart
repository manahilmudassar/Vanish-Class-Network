import 'package:flutter/foundation.dart';

/// Service responsible for maintaining time synchronization with the relay server.
/// 
/// Assignment requirement:
/// "Countdown must eventually be based on server-provided expires_at and
/// synchronized server time, not simply a timer restarted when a message is received."
class TimeSyncService extends ChangeNotifier {
  static final TimeSyncService _instance = TimeSyncService._internal();
  factory TimeSyncService() => _instance;
  TimeSyncService._internal();

  Duration _serverClockOffset = Duration.zero;
  bool _hasSynced = false;
  DateTime? _lastSyncAttempt;
  String? _lastSyncError;

  Duration get serverClockOffset => _serverClockOffset;
  bool get hasSynced => _hasSynced;
  DateTime? get lastSyncAttempt => _lastSyncAttempt;
  String? get lastSyncError => _lastSyncError;

  /// Returns the current synchronized server time.
  DateTime get synchronizedNow {
    return DateTime.now().toUtc().add(_serverClockOffset);
  }

  /// Updates the server time offset based on a known server timestamp and request round-trip time.
  void updateServerTime(DateTime serverTime, {Duration roundTripDelay = Duration.zero}) {
    final clientUtc = DateTime.now().toUtc();
    // Estimate server time at response arrival: serverTime + (RTT / 2)
    final adjustedServerTime = serverTime.add(Duration(milliseconds: roundTripDelay.inMilliseconds ~/ 2));
    _serverClockOffset = adjustedServerTime.difference(clientUtc);
    _hasSynced = true;
    _lastSyncAttempt = DateTime.now();
    _lastSyncError = null;
    notifyListeners();
  }

  /// Updates the server time using the HTTP 'Date' header returned by the server.
  void updateFromHttpDateHeader(String? dateHeader, {Duration roundTripDelay = Duration.zero}) {
    if (dateHeader == null || dateHeader.isEmpty) return;
    try {
      final parsed = _parseHttpDate(dateHeader);
      if (parsed != null) {
        updateServerTime(parsed, roundTripDelay: roundTripDelay);
      }
    } catch (e) {
      _lastSyncError = 'Failed to parse HTTP Date header: $e';
      notifyListeners();
    }
  }

  /// Updates server clock offset using Vanish Relay Protocol v1 Section 9:
  /// offset = server_time - phone_time
  void updateFromRelayServerTime(int serverTimeMs) {
    final phoneTimeMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final offsetMs = serverTimeMs - phoneTimeMs;
    _serverClockOffset = Duration(milliseconds: offsetMs);
    _hasSynced = true;
    _lastSyncAttempt = DateTime.now();
    _lastSyncError = null;
    notifyListeners();
  }

  /// Marks a synchronization failure.
  void recordSyncFailure(String error) {
    _lastSyncError = error;
    _lastSyncAttempt = DateTime.now();
    notifyListeners();
  }

  @visibleForTesting
  void setClockOffsetForTesting(Duration offset) {
    _serverClockOffset = offset;
    _hasSynced = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTesting() {
    _serverClockOffset = Duration.zero;
    _hasSynced = false;
    _lastSyncAttempt = null;
    _lastSyncError = null;
    notifyListeners();
  }

  /// Standard HTTP Date header parser (RFC 1123 / RFC 822 format, e.g. "Sun, 06 Nov 1994 08:49:37 GMT")
  static DateTime? _parseHttpDate(String dateString) {
    try {
      return DateTime.parse(dateString).toUtc();
    } catch (_) {
      // Manual parse for RFC 1123 format if standard parser fails
      try {
        final parts = dateString.split(' ');
        if (parts.length >= 5) {
          // e.g. "Mon, 16 Nov 2026 13:00:00 GMT"
          final day = int.tryParse(parts[1]);
          final months = {
            'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
            'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
          };
          final month = months[parts[2]];
          final year = int.tryParse(parts[3]);
          final timeParts = parts[4].split(':');
          if (day != null && month != null && year != null && timeParts.length == 3) {
            final hour = int.tryParse(timeParts[0]) ?? 0;
            final minute = int.tryParse(timeParts[1]) ?? 0;
            final second = int.tryParse(timeParts[2]) ?? 0;
            return DateTime.utc(year, month, day, hour, minute, second);
          }
        }
      } catch (_) {}
    }
    return null;
  }
}
