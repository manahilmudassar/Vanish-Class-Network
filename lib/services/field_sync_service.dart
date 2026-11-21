import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sync_record.dart';
import '../utils/constants.dart';
import 'time_sync_service.dart';

enum ConnectionStateStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class ServerHealthResult {
  final bool isHealthy;
  final String message;
  final int latencyMs;
  final int? serverTimestamp;

  const ServerHealthResult({
    required this.isHealthy,
    required this.message,
    required this.latencyMs,
    this.serverTimestamp,
  });
}

class SyncPushResult {
  final bool success;
  final int count;
  final String? errorMessage;

  const SyncPushResult({
    required this.success,
    required this.count,
    this.errorMessage,
  });
}

class SyncPullResult {
  final bool success;
  final List<SyncRecord> records;
  final int? latestTimestamp;
  final String? errorMessage;

  const SyncPullResult({
    required this.success,
    required this.records,
    this.latestTimestamp,
    this.errorMessage,
  });
}

/// Service integrating with the teacher-provided `field-sync` API.
/// 
/// Supported endpoints per teacher specification:
/// - GET /health
/// - POST /sync/push
/// - GET /sync/pull?since=...
/// - GET /records/{record_id}
/// 
/// API Limitations Report:
/// - No WebSocket / Server-Sent Events (SSE) support: Real-time updates require periodic pull polling.
/// - No native server-side message expiry: Server stores records without TTL deletion; the client must manage 30s vanishing logic locally.
/// - No chat room routing: Records are synchronized uniformly across the endpoint; room filtering is managed at the client application layer.
/// - No real-time delivery receipts: Server does not notify senders when a peer pulls a record.
class FieldSyncService extends ChangeNotifier {
  static final FieldSyncService _instance = FieldSyncService._internal();
  factory FieldSyncService() => _instance;
  FieldSyncService._internal();

  final http.Client _client = http.Client();
  final TimeSyncService _timeSyncService = TimeSyncService();

  String _baseUrl = AppConstants.defaultServerUrl;
  ConnectionStateStatus _status = ConnectionStateStatus.disconnected;
  String? _lastError;
  DateTime? _lastSuccessfulSync;
  int _lastServerTimestamp = 0;

  String get baseUrl => _baseUrl;
  ConnectionStateStatus get status => _status;
  bool get isConnected => _status == ConnectionStateStatus.connected;
  String? get lastError => _lastError;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;
  int get lastServerTimestamp => _lastServerTimestamp;

  /// Loads saved server URL preference.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(AppConstants.prefKeyServerUrl);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _baseUrl = savedUrl.trim();
    }
    notifyListeners();
  }

  /// Updates and persists the server base URL.
  Future<void> setBaseUrl(String url) async {
    var formatted = url.trim();
    if (formatted.endsWith('/')) {
      formatted = formatted.substring(0, formatted.length - 1);
    }
    _baseUrl = formatted;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyServerUrl, formatted);
    notifyListeners();
  }

  /// Checks server health via GET /health and synchronizes server clock.
  Future<ServerHealthResult> checkHealth() async {
    _status = ConnectionStateStatus.connecting;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse('$_baseUrl/health');
      final response = await _client.get(uri).timeout(
            const Duration(seconds: 4),
          );
      stopwatch.stop();

      // Synchronize time from HTTP Date header
      final dateHeader = response.headers['date'];
      _timeSyncService.updateFromHttpDateHeader(
        dateHeader,
        roundTripDelay: stopwatch.elapsed,
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        int? serverTs;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            final ts = decoded['time'] ?? decoded['timestamp'];
            if (ts is int) {
              serverTs = ts;
              _timeSyncService.updateServerTime(
                DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
                roundTripDelay: stopwatch.elapsed,
              );
            }
          }
        } catch (_) {
          // If JSON body does not include time, HTTP Date header was already used
        }

        _status = ConnectionStateStatus.connected;
        _lastError = null;
        _lastSuccessfulSync = DateTime.now();
        notifyListeners();
        return ServerHealthResult(
          isHealthy: true,
          message: 'Server online (${stopwatch.elapsedMilliseconds}ms)',
          latencyMs: stopwatch.elapsedMilliseconds,
          serverTimestamp: serverTs,
        );
      } else {
        final err = 'Server returned HTTP ${response.statusCode}: ${response.reasonPhrase}';
        _status = ConnectionStateStatus.error;
        _lastError = err;
        notifyListeners();
        return ServerHealthResult(
          isHealthy: false,
          message: err,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
      }
    } on SocketException catch (e) {
      stopwatch.stop();
      final err = 'Cannot reach $_baseUrl (${e.osError?.message ?? e.message})';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      _timeSyncService.recordSyncFailure(err);
      notifyListeners();
      return ServerHealthResult(
        isHealthy: false,
        message: err,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on TimeoutException {
      stopwatch.stop();
      final err = 'Connection to $_baseUrl timed out';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      _timeSyncService.recordSyncFailure(err);
      notifyListeners();
      return ServerHealthResult(
        isHealthy: false,
        message: err,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } catch (e) {
      stopwatch.stop();
      final err = 'Connection error: $e';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      _timeSyncService.recordSyncFailure(err);
      notifyListeners();
      return ServerHealthResult(
        isHealthy: false,
        message: err,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// Pushes sync records to the server via POST /sync/push.
  /// 
  /// Does NOT simulate success. If the request fails, returns actual error details.
  Future<SyncPushResult> pushRecords(List<SyncRecord> records) async {
    if (records.isEmpty) {
      return const SyncPushResult(success: true, count: 0);
    }

    try {
      final uri = Uri.parse('$_baseUrl/sync/push');
      final recordsJson = records.map((r) => r.toJson()).toList();
      
      // Support both { "records": [...] } and raw [...] payloads
      final payload = jsonEncode({'records': recordsJson});
      
      final response = await _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: payload,
      ).timeout(const Duration(seconds: 5));

      // Extract server time from response header
      _timeSyncService.updateFromHttpDateHeader(response.headers['date']);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _status = ConnectionStateStatus.connected;
        _lastError = null;
        _lastSuccessfulSync = DateTime.now();
        notifyListeners();
        return SyncPushResult(success: true, count: records.length);
      } else {
        final err = 'Push failed (HTTP ${response.statusCode}): ${response.body}';
        _status = ConnectionStateStatus.error;
        _lastError = err;
        notifyListeners();
        return SyncPushResult(success: false, count: 0, errorMessage: err);
      }
    } on SocketException catch (e) {
      final err = 'Network error during push: ${e.message}';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return SyncPushResult(success: false, count: 0, errorMessage: err);
    } on TimeoutException {
      const err = 'Timeout while pushing records to server';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return const SyncPushResult(success: false, count: 0, errorMessage: err);
    } catch (e) {
      final err = 'Push error: $e';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return SyncPushResult(success: false, count: 0, errorMessage: err);
    }
  }

  /// Pulls sync records from the server via GET /sync/pull?since={timestamp}.
  /// 
  /// Extracts newly received records and records their arrival timestamp.
  Future<SyncPullResult> pullRecords({required int since}) async {
    try {
      final uri = Uri.parse('$_baseUrl/sync/pull?since=$since');
      final response = await _client.get(uri).timeout(
            const Duration(seconds: 5),
          );

      _timeSyncService.updateFromHttpDateHeader(response.headers['date']);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _status = ConnectionStateStatus.connected;
        _lastError = null;
        _lastSuccessfulSync = DateTime.now();

        final decoded = jsonDecode(response.body);
        final List<dynamic> rawList;
        int? serverLatestTs;

        if (decoded is List) {
          rawList = decoded;
        } else if (decoded is Map) {
          rawList = (decoded['records'] as List?) ?? [];
          serverLatestTs = decoded['latest_timestamp'] as int? ??
              decoded['timestamp'] as int?;
        } else {
          rawList = [];
        }

        final records = <SyncRecord>[];
        for (final item in rawList) {
          if (item is Map<String, dynamic>) {
            records.add(SyncRecord.fromJson(item));
          } else if (item is Map) {
            records.add(SyncRecord.fromJson(Map<String, dynamic>.from(item)));
          }
        }

        if (records.isNotEmpty) {
          final maxTs = records.map((r) => r.timestamp).reduce((a, b) => a > b ? a : b);
          if (maxTs > _lastServerTimestamp) {
            _lastServerTimestamp = maxTs;
          }
        }

        notifyListeners();
        return SyncPullResult(
          success: true,
          records: records,
          latestTimestamp: serverLatestTs ?? _lastServerTimestamp,
        );
      } else {
        final err = 'Pull failed (HTTP ${response.statusCode}): ${response.reasonPhrase}';
        _status = ConnectionStateStatus.error;
        _lastError = err;
        notifyListeners();
        return SyncPullResult(success: false, records: const [], errorMessage: err);
      }
    } on SocketException catch (e) {
      final err = 'Cannot pull from $_baseUrl: ${e.message}';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return SyncPullResult(success: false, records: const [], errorMessage: err);
    } on TimeoutException {
      const err = 'Timeout while pulling records';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return const SyncPullResult(success: false, records: [], errorMessage: err);
    } catch (e) {
      final err = 'Pull error: $e';
      _status = ConnectionStateStatus.error;
      _lastError = err;
      notifyListeners();
      return SyncPullResult(success: false, records: const [], errorMessage: err);
    }
  }

  /// Retrieves a specific record by ID via GET /records/{record_id}.
  Future<SyncRecord?> getRecord(String recordId) async {
    try {
      final uri = Uri.parse('$_baseUrl/records/$recordId');
      final response = await _client.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return SyncRecord.fromJson(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  @visibleForTesting
  void setStatusForTesting(ConnectionStateStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
