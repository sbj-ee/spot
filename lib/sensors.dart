import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'precise_mark.dart';

/// Thin seam over the location + compass plugins so the home screen can be
/// driven by fakes in widget tests.
abstract class SpotSensors {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<bool> openAppSettings();

  /// Live high-accuracy position updates for the main screen.
  Stream<Position> positionStream();
  Future<Position?> lastKnownPosition();

  /// Device heading in degrees (0 = north), or null when the device has no
  /// compass. Events may carry a null heading while uncalibrated.
  Stream<double?>? headings();

  /// Degrees to add to [headings] to get a true-north heading at this
  /// place (the magnetic declination where the platform reports magnetic
  /// north, 0 where it already reports true north).
  Future<double> headingCorrection({
    required double latitude,
    required double longitude,
    double altitude = 0,
  });

  /// Keep the screen on (while walking back to the spot) or release it.
  Future<void> setKeepAwake(bool on);
}

/// Real device implementation backed by geolocator + flutter_compass.
class DeviceSensors implements SpotSensors {
  const DeviceSensors();

  static const _geomag = MethodChannel('ee.sbj.spot/geomag');

  @override
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Stream<Position> positionStream() =>
      Geolocator.getPositionStream(locationSettings: highAccuracySettings());

  @override
  Future<Position?> lastKnownPosition() => Geolocator.getLastKnownPosition();

  @override
  Stream<double?>? headings() {
    final events = FlutterCompass.events;
    if (events == null) return null;
    final filter = CompassReliabilityFilter();
    return events.map((e) => filter.heading(e.heading, e.accuracy));
  }

  @override
  Future<double> headingCorrection({
    required double latitude,
    required double longitude,
    double altitude = 0,
  }) async {
    // flutter_compass: magnetic north on Android, true north on iOS.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return 0;
    final deg = await _geomag.invokeMethod<double>('declination', {
      'lat': latitude,
      'lon': longitude,
      'alt': altitude.isFinite ? altitude : 0.0,
    });
    return deg ?? 0;
  }

  @override
  Future<void> setKeepAwake(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('Spot: wakelock failed: $e');
    }
  }
}

/// Drops compass readings the plugin flags as unreliable.
///
/// flutter_compass 0.8.1 exposes only [CompassEvent.accuracy]: on Android
/// 15/30/45 degrees for high/medium/low sensor accuracy, and null for
/// SENSOR_STATUS_UNRELIABLE. Null is also what a device that never reports
/// accuracy sends, so null only counts as unreliable once that device has
/// reported a real accuracy at least once; otherwise the compass would go
/// dark on phones that never report one.
class CompassReliabilityFilter {
  bool _seenAccuracy = false;

  /// [heading] when it is usable, else null (treated as uncalibrated).
  double? heading(double? heading, double? accuracy) {
    if (accuracy != null) {
      _seenAccuracy = true;
      return heading;
    }
    return _seenAccuracy ? null : heading;
  }
}
