import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

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
}

/// Real device implementation backed by geolocator + flutter_compass.
class DeviceSensors implements SpotSensors {
  const DeviceSensors();

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
  Stream<double?>? headings() => FlutterCompass.events?.map((e) => e.heading);
}
