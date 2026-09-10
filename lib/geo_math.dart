import 'dart:math' as math;

/// Normalize degrees into [0, 360).
double normalizeDegrees(double deg) {
  var d = deg % 360.0;
  if (d < 0) d += 360.0;
  return d;
}

/// Smallest signed turn from [fromDeg] to [toDeg], in (-180, 180].
double shortestAngleDelta(double fromDeg, double toDeg) {
  return (normalizeDegrees(toDeg - fromDeg + 180.0) - 180.0);
}

/// Human distance: feet under 0.5 mi, else miles.
String formatDistance(double meters) {
  final miles = meters / 1609.344;
  if (miles < 0.5) {
    final feet = meters * 3.280839895;
    if (feet < 10) return '${feet.toStringAsFixed(1)} ft';
    return '${feet.round()} ft';
  }
  if (miles < 10) return '${miles.toStringAsFixed(2)} mi';
  return '${miles.toStringAsFixed(1)} mi';
}

String formatAccuracyFeet(double? accuracyMeters) {
  if (accuracyMeters == null || accuracyMeters.isNaN) return '±? ft';
  final feet = accuracyMeters * 3.280839895;
  if (feet < 10) return '±${feet.toStringAsFixed(1)} ft';
  return '±${feet.round()} ft';
}

String formatFixAge(DateTime? timestamp) {
  if (timestamp == null) return 'age unknown';
  final age = DateTime.now().difference(timestamp);
  if (age.inSeconds < 2) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}

/// Compass rose letter for absolute bearing (optional UI).
String bearingCardinal(double bearingDeg) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final i = ((normalizeDegrees(bearingDeg) + 22.5) % 360 ~/ 45) % 8;
  return dirs[i];
}

double degToRad(double deg) => deg * math.pi / 180.0;
