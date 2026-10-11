import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:spot/sensors.dart';

Position fakePosition({
  double lat = 41.8781,
  double lon = -87.6298,
  double accuracy = 3,
  double speed = 0,
  double heading = 0,
}) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime.now(),
  accuracy: accuracy,
  altitude: 180,
  altitudeAccuracy: 2,
  heading: heading,
  headingAccuracy: 0,
  speed: speed,
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
  bool keepAwake = false;
  double headingCorrectionDeg = 0;

  // Broadcast, like the plugin's stream: the live screen and the mark
  // collector may both listen. Counts track first-listen / last-cancel.
  late final StreamController<Position> _pos =
      StreamController<Position>.broadcast(
        onListen: () => positionListens++,
        onCancel: () => positionCancels++,
      );
  StreamController<double?>? _compass;

  bool get positionListening => _pos.hasListener;
  bool get compassListening => _compass?.hasListener ?? false;

  void emitPosition(Position p) => _pos.add(p);
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
  Stream<Position> positionStream() => _pos.stream;

  @override
  Future<Position?> lastKnownPosition() async => lastKnown;

  @override
  Future<double> headingCorrection({
    required double latitude,
    required double longitude,
    double altitude = 0,
  }) async => headingCorrectionDeg;

  @override
  Future<void> setKeepAwake(bool on) async => keepAwake = on;

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
