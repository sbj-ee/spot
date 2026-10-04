import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Best-effort native diagnostics (Android only). Never throws.
class DiagPlatform {
  static const _ch = MethodChannel('ee.sbj.spot/diag');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<Map<String, Object?>> deviceInfo() async {
    if (!_android) return {'platform': defaultTargetPlatform.name};
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('deviceInfo');
      return {'platform': 'android', ...?m};
    } catch (e) {
      return {'platform': 'android', 'device_info_error': '$e'};
    }
  }

  static Future<void> keepScreenOn(bool on) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<bool>('keepScreenOn', {'on': on});
    } catch (e) {
      debugPrint('Spot: keepScreenOn failed: $e');
    }
  }

  /// Which Android provider geolocator 5.x actually uses for this build's
  /// request. Mirrors LocationManagerClient.determineProvider when
  /// forceLocationManager is true (FUSED_PROVIDER first on API 31+, then
  /// gps, then network); otherwise Play services FusedLocationProviderClient.
  static String effectiveProvider({
    required bool forceLocationManager,
    required Map<String, Object?> info,
  }) {
    if (!forceLocationManager) return 'play_services_fused (FusedLocationProviderClient)';
    final enabled = (info['enabled_providers'] as List?)?.cast<Object?>() ?? const [];
    final sdk = info['sdk_int'] is int ? info['sdk_int'] as int : 0;
    if (enabled.contains('fused') && sdk >= 31) return 'LocationManager:fused';
    if (enabled.contains('gps')) return 'LocationManager:gps';
    if (enabled.contains('network')) return 'LocationManager:network';
    return 'LocationManager:unknown';
  }
}
