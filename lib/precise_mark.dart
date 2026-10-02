import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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

/// Key under NSLocationTemporaryUsageDescriptionDictionary in
/// ios/Runner/Info.plist. Must match exactly, or iOS rejects the
/// temporary full-accuracy request. Guarded by test/purpose_key_test.dart.
const String kPreciseAccuracyPurposeKey = 'PreciseAccuracy';

enum PreciseAccuracyOutcome {
  /// Location was already precise.
  precise,

  /// Was reduced; the user granted temporary full accuracy (iOS).
  upgraded,

  /// Still reduced (user declined, or the platform can't ask in-app).
  reduced,

  /// Checking or requesting accuracy threw.
  failed,
}

class PreciseAccuracyCheck {
  const PreciseAccuracyCheck(this.outcome, [this.message]);

  final PreciseAccuracyOutcome outcome;

  /// User-facing warning, null when location is precise.
  final String? message;

  bool get isPrecise =>
      outcome == PreciseAccuracyOutcome.precise ||
      outcome == PreciseAccuracyOutcome.upgraded;
}

/// Make sure the OS gives us precise (not approximate) fixes before marking.
///
/// On iOS a reduced-accuracy grant can be lifted for this session with
/// [requestTemporaryFullAccuracy] using [kPreciseAccuracyPurposeKey]. Android
/// has no in-app temporary upgrade, so we only report it. Failures are
/// returned (and logged), never swallowed.
Future<PreciseAccuracyCheck> ensurePreciseAccuracy({
  Future<LocationAccuracyStatus> Function()? getAccuracy,
  Future<LocationAccuracyStatus> Function(String purposeKey)?
  requestTemporaryFullAccuracy,
  bool? canRequestTemporary,
}) async {
  final get = getAccuracy ?? Geolocator.getLocationAccuracy;
  final request =
      requestTemporaryFullAccuracy ??
      (String key) => Geolocator.requestTemporaryFullAccuracy(purposeKey: key);
  final canAsk =
      canRequestTemporary ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
  try {
    final status = await get();
    if (status == LocationAccuracyStatus.precise) {
      return const PreciseAccuracyCheck(PreciseAccuracyOutcome.precise);
    }
    if (!canAsk) {
      return const PreciseAccuracyCheck(
        PreciseAccuracyOutcome.reduced,
        'Approximate location only. Turn on Precise location in Settings.',
      );
    }
    final after = await request(kPreciseAccuracyPurposeKey);
    if (after == LocationAccuracyStatus.precise) {
      return const PreciseAccuracyCheck(PreciseAccuracyOutcome.upgraded);
    }
    return const PreciseAccuracyCheck(
      PreciseAccuracyOutcome.reduced,
      'Precise location declined. Mark will be approximate.',
    );
  } catch (e) {
    debugPrint('Spot: precise accuracy check failed: $e');
    return PreciseAccuracyCheck(
      PreciseAccuracyOutcome.failed,
      'Could not get precise location: $e',
    );
  }
}


class PreciseMarkResult {
  const PreciseMarkResult({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.sampleCount,
    required this.altitudeMeters,
    required this.forced,
    this.accuracyWarning,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final int sampleCount;
  final double? altitudeMeters;
  final bool forced; // user overrode / timeout with best available

  /// Set when the OS only gave approximate location (or the check failed).
  final String? accuracyWarning;

  PreciseMarkResult withAccuracyWarning(String? warning) => PreciseMarkResult(
    latitude: latitude,
    longitude: longitude,
    accuracyMeters: accuracyMeters,
    sampleCount: sampleCount,
    altitudeMeters: altitudeMeters,
    forced: forced,
    accuracyWarning: warning,
  );
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
  final accuracyCheck = await ensurePreciseAccuracy();
  final accuracyWarning = accuracyCheck.message;
  if (accuracyWarning != null) {
    onProgress(accuracyWarning, null);
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
    completer.complete(result?.withAccuracyWarning(accuracyWarning));
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
