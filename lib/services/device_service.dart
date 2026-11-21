import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../utils/constants.dart';

/// Manages persistent device identity and user profile settings.
class DeviceService extends ChangeNotifier {
  static final DeviceService _instance = DeviceService._internal();
  factory DeviceService() => _instance;
  DeviceService._internal();

  String _deviceId = '';
  String _displayName = '';
  bool _isInitialized = false;

  String get deviceId => _deviceId;
  String get displayName => _displayName;
  bool get isInitialized => _isInitialized;

  /// Short format for display in compact UI badges
  String get shortDeviceId {
    if (_deviceId.length > 12) {
      return _deviceId.substring(0, 12);
    }
    return _deviceId;
  }

  /// Initializes device ID and loads stored display name.
  Future<void> initialize() async {
    if (_isInitialized) return;
    final prefs = await SharedPreferences.getInstance();

    String? existingId = prefs.getString(AppConstants.prefKeyDeviceId);
    if (existingId == null || existingId.isEmpty) {
      // Generate a new persistent unique device ID
      final uuid = const Uuid().v4();
      existingId = 'dev_${uuid.substring(0, 8)}';
      await prefs.setString(AppConstants.prefKeyDeviceId, existingId);
    }
    _deviceId = existingId;

    _displayName = prefs.getString(AppConstants.prefKeyDisplayName) ?? '';
    _isInitialized = true;
    notifyListeners();
  }

  /// Persists and updates user display name.
  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    _displayName = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyDisplayName, trimmed);
    notifyListeners();
  }
}
