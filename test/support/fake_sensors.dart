import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:spot/sensors.dart';

Position fakePosition({
  double lat = 41.8781,
  double lon = -87.6298,
  double accuracy = 3,
}) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime.now(),
  accuracy: accuracy,
  altitude: 180,
  altitudeAccuracy: 2,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

/// Scriptable stand-in for the GPS + compass plugins.
class FakeSensors implements SpotSensors {
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission permissionAfterRequest = LocationPermission.whileInUse;
  bool hasCompass = true;
  Position? lastKnown;

  int requestPermissionCalls = 0;
  int openAppSettingsCalls = 0;
  int positionListens = 0;
  int positionCancels = 0;
  int compassListens = 0;
  int compassCancels = 0;

  StreamController<Position>? _pos;
  StreamController<double?>? _compass;

  bool get positionListening => _pos?.hasListener ?? false;
  bool get compassListening => _compass?.hasListener ?? false;

  void emitPosition(Position p) => _pos?.add(p);
  void emitHeading(double? h) => _compass?.add(h);

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    permission = permissionAfterRequest;
    return permission;
  }

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }

  @override
  Stream<Position> positionStream() {
    final c = StreamController<Position>(
      onListen: () => positionListens++,
      onCancel: () => positionCancels++,
    );
    _pos = c;
    return c.stream;
  }

  @override
  Future<Position?> lastKnownPosition() async => lastKnown;

  @override
  Stream<double?>? headings() {
    if (!hasCompass) return null;
    final c = StreamController<double?>(
      onListen: () => compassListens++,
      onCancel: () => compassCancels++,
    );
    _compass = c;
    return c.stream;
  }
}
