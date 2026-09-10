import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

/// High-accuracy mark settings. Prefer GNSS over coarse network fixes.
LocationSettings highAccuracySettings({Duration? interval}) {
  return AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    forceLocationManager: true,
    intervalDuration: interval ?? const Duration(milliseconds: 500),
    // Foreground notification not required for short mark sessions.
  );
}

const double kReadyAccuracyMeters = 5.0; // ~16 ft — Mark enabled at/under this
const double kAcceptAccuracyMeters = 8.0; // drop worse samples while averaging
const int kMinGoodSamples = 5;
const Duration kMarkTimeout = Duration(seconds: 25);
const Duration kWarmupIgnore = Duration(seconds: 2); // discard first fixes

class PreciseMarkResult {
  const PreciseMarkResult({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.sampleCount,
    required this.altitudeMeters,
    required this.forced,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final int sampleCount;
  final double? altitudeMeters;
  final bool forced; // user overrode / timeout with best available
}

bool isFixUsable(Position p, {required double maxAccuracyMeters}) {
  if (!p.latitude.isFinite || !p.longitude.isFinite) return false;
  if (p.accuracy <= 0 || p.accuracy > maxAccuracyMeters) return false;
  // Reject absurd coordinates
  if (p.latitude.abs() > 90 || p.longitude.abs() > 180) return false;
  return true;
}

/// Average lat/lon of [samples], report accuracy as max(sample accuracies,
/// 1σ radius of the cloud) so a tight cluster with claimed 3 m each still
/// reflects scatter.
PreciseMarkResult averageSamples(List<Position> samples, {required bool forced}) {
  assert(samples.isNotEmpty);
  var sumLat = 0.0;
  var sumLon = 0.0;
  var sumAlt = 0.0;
  var altN = 0;
  var worstAcc = 0.0;
  for (final p in samples) {
    sumLat += p.latitude;
    sumLon += p.longitude;
    worstAcc = math.max(worstAcc, p.accuracy);
    if (p.altitude.isFinite) {
      sumAlt += p.altitude;
      altN++;
    }
  }
  final n = samples.length;
  final meanLat = sumLat / n;
  final meanLon = sumLon / n;

  // Rough meters-per-degree at this latitude for scatter estimate.
  final mPerDegLat = 111320.0;
  final mPerDegLon = 111320.0 * math.cos(meanLat * math.pi / 180.0).abs().clamp(0.2, 1.0);
  var sumSq = 0.0;
  for (final p in samples) {
    final dy = (p.latitude - meanLat) * mPerDegLat;
    final dx = (p.longitude - meanLon) * mPerDegLon;
    sumSq += dx * dx + dy * dy;
  }
  final sigma = math.sqrt(sumSq / n);
  final accuracy = math.max(worstAcc, sigma);

  return PreciseMarkResult(
    latitude: meanLat,
    longitude: meanLon,
    accuracyMeters: accuracy,
    sampleCount: n,
    altitudeMeters: altN > 0 ? sumAlt / altN : null,
    forced: forced,
  );
}

/// Collect GNSS samples until [kMinGoodSamples] at ≤ [kReadyAccuracyMeters],
/// or [timeout]. Returns null if nothing usable (caller may force with stream).
Future<PreciseMarkResult?> collectPreciseMark({
  required void Function(String status, Position? latest) onProgress,
  Duration timeout = kMarkTimeout,
  bool forceWithBest = false,
}) async {
  // Nudge Android into high-accuracy mode if location is on but coarse.
  try {
    final accuracy = await Geolocator.getLocationAccuracy();
    if (accuracy == LocationAccuracyStatus.reduced) {
      onProgress('Enable precise / high-accuracy location', null);
      await Geolocator.requestTemporaryFullAccuracy(purposeKey: 'SpotMark');
    }
  } catch (_) {
    // Android may not support temporary full accuracy; continue.
  }

  final started = DateTime.now();
  final good = <Position>[];
  Position? best; // lowest accuracy value among all seen

  final stream = Geolocator.getPositionStream(
    locationSettings: highAccuracySettings(),
  );

  final completer = Completer<PreciseMarkResult?>();
  late StreamSubscription<Position> sub;
  Timer? timeoutTimer;

  void finish(PreciseMarkResult? result) {
    if (completer.isCompleted) return;
    timeoutTimer?.cancel();
    sub.cancel();
    completer.complete(result);
  }

  timeoutTimer = Timer(timeout, () {
    if (good.length >= 2) {
      finish(averageSamples(good, forced: true));
    } else if (best != null && forceWithBest) {
      finish(averageSamples([best!], forced: true));
    } else if (best != null) {
      finish(averageSamples([best!], forced: true));
    } else {
      finish(null);
    }
  });

  sub = stream.listen((pos) {
    final elapsed = DateTime.now().difference(started);
    if (best == null || pos.accuracy < best!.accuracy) {
      best = pos;
    }

    // Warm-up: ignore first seconds (often a cached/network jump).
    if (elapsed < kWarmupIgnore) {
      onProgress(
        'Warming up GPS… ${formatAcc(pos.accuracy)}',
        pos,
      );
      return;
    }

    onProgress('Sampling… ${formatAcc(pos.accuracy)}', pos);

    if (!isFixUsable(pos, maxAccuracyMeters: kAcceptAccuracyMeters)) {
      return;
    }
    // Reject huge jumps from current mean if we have samples.
    if (good.isNotEmpty) {
      final mean = averageSamples(good, forced: false);
      final jump = Geolocator.distanceBetween(
        mean.latitude,
        mean.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (jump > math.max(25.0, pos.accuracy * 3)) {
        return;
      }
    }

    if (pos.accuracy <= kReadyAccuracyMeters) {
      good.add(pos);
    }

    if (good.length >= kMinGoodSamples) {
      onProgress('Locked ${good.length} samples', pos);
      finish(averageSamples(good, forced: false));
    }
  }, onError: (e) {
    onProgress('GPS error: $e', null);
    if (good.isNotEmpty) {
      finish(averageSamples(good, forced: true));
    } else {
      finish(null);
    }
  });

  return completer.future;
}

String formatAcc(double meters) {
  final ft = meters * 3.280839895;
  if (ft < 10) return '±${ft.toStringAsFixed(1)} ft';
  return '±${ft.round()} ft';
}
