import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Service responsible for monitoring device network interface connectivity (Wi-Fi, Mobile, etc.).
/// 
/// Distinguishes hardware network availability from server reachability:
/// - Hardware network availability: is device connected to Wi-Fi/Cellular?
/// - Server reachability: can device reach the configured relay server?
class ConnectivityService extends ChangeNotifier {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _isNetworkAvailable = true;
  bool _isInitialized = false;

  /// Callback triggered when connectivity transitions from offline to online.
  VoidCallback? onConnectivityRestored;
  VoidCallback? onConnectivityLost;

  bool get isNetworkAvailable => _isNetworkAvailable;
  bool get isInitialized => _isInitialized;
  bool get isListening => _subscription != null;

  /// Initializes connectivity monitoring.
  Future<void> initialize({Connectivity? connectivity}) async {
    if (connectivity != null) {
      _connectivity = connectivity;
    }
    if (_subscription != null) return;

    try {
      final initialResults = await _connectivity.checkConnectivity();
      _updateFromResults(initialResults, notify: false);
    } catch (_) {
      // Fallback: assume available if platform channel is unavailable (e.g. unit tests)
      _isNetworkAvailable = true;
    }

    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      final wasAvailable = _isNetworkAvailable;
      _updateFromResults(results, notify: true);
      if (!wasAvailable && _isNetworkAvailable) {
        onConnectivityRestored?.call();
      } else if (wasAvailable && !_isNetworkAvailable) {
        onConnectivityLost?.call();
      }
    });

    _isInitialized = true;
    notifyListeners();
  }

  void _updateFromResults(List<ConnectivityResult> results, {bool notify = true}) {
    final available = results.any((r) => r != ConnectivityResult.none);
    if (_isNetworkAvailable != available || !_isInitialized) {
      _isNetworkAvailable = available;
      if (notify) {
        notifyListeners();
      }
    }
  }

  /// Cancels subscription and cleans up resources.
  void disposeService() {
    _subscription?.cancel();
    _subscription = null;
    _isInitialized = false;
  }

  @visibleForTesting
  void setNetworkAvailableForTesting(bool available, {bool triggerRestored = true}) {
    final wasAvailable = _isNetworkAvailable;
    _isNetworkAvailable = available;
    notifyListeners();
    if (!wasAvailable && available && triggerRestored) {
      onConnectivityRestored?.call();
    } else if (wasAvailable && !available) {
      onConnectivityLost?.call();
    }
  }

  @visibleForTesting
  void resetForTesting() {
    disposeService();
    _isNetworkAvailable = true;
    onConnectivityRestored = null;
    onConnectivityLost = null;
  }
}
