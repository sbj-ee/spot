import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'diagnostics.dart';

/// High-accuracy location settings for the live screen and for marking.
///
/// Android: goes through Google Play services' FusedLocationProviderClient
/// with PRIORITY_HIGH_ACCURACY (geolocator maps high/best/bestForNavigation
/// to that priority), a 1 s interval and no distance filter.
///
/// Do not set forceLocationManager: on Android 12+ geolocator's
/// LocationManager path picks LocationManager.FUSED_PROVIDER ahead of
/// GPS_PROVIDER, so it never gave GNSS-only fixes; it only bypassed the Play
/// services fused provider. bestForNavigation is kept for iOS
/// (kCLLocationAccuracyBestForNavigation); on Android it equals best/high.
/// Whether the Android request bypasses Play services (see diagnostics).
const bool kForceLocationManager = false;

LocationSettings highAccuracySettings({Duration? interval}) {
  return AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    forceLocationManager: kForceLocationManager,
    intervalDuration: interval ?? const Duration(seconds: 1),
    // Foreground notification not required for short mark sessions.
  );
}

/// Mark locks when the accuracy-weighted estimate over the window is at or
/// under this (~16 ft). Also the live "Ready" threshold.
const double kReadyAccuracyMeters = 5.0;

/// Samples worse than this (~49 ft) are dropped. Anything better counts,
/// weighted by 1/accuracy², so a 10 m fix barely moves a 4 m cluster.
const double kAcceptAccuracyMeters = 15.0;

/// Minimum samples in the window before Mark can lock.
const int kMinGoodSamples = 5;

/// Sliding window of the most recent accepted samples.
const int kSampleWindow = 10;
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
  if (!p.accuracy.isFinite) return false;
  if (p.accuracy <= 0 || p.accuracy > maxAccuracyMeters) return false;
  // Reject absurd coordinates
  if (p.latitude.abs() > 90 || p.longitude.abs() > 180) return false;
  return true;
}

/// Accuracy-weighted average of [samples] (weight 1/accuracy²).
///
/// Reported accuracy is max(weighted RMS of the claimed accuracies, weighted
/// 1σ scatter of the cloud). It deliberately does not shrink by √N: GNSS
/// errors are strongly correlated over a few seconds, so averaging a
/// stationary phone does not make the fix N times better.
PreciseMarkResult averageSamples(List<Position> samples, {required bool forced}) {
  assert(samples.isNotEmpty);
  var sumW = 0.0;
  var sumLat = 0.0;
  var sumLon = 0.0;
  var sumAltW = 0.0;
  var altW = 0.0;
  for (final p in samples) {
    final acc = math.max(p.accuracy, 0.1);
    final w = 1.0 / (acc * acc);
    sumW += w;
    sumLat += w * p.latitude;
    sumLon += w * p.longitude;
    if (p.altitude.isFinite) {
      sumAltW += w * p.altitude;
      altW += w;
    }
  }
  final n = samples.length;
  final meanLat = sumLat / sumW;
  final meanLon = sumLon / sumW;
  // Weighted RMS of accuracies: sqrt(n / Σ 1/acc²). Equals acc when all agree.
  final claimed = math.sqrt(n / sumW);

  // Rough meters-per-degree at this latitude for scatter estimate.
  const mPerDegLat = 111320.0;
  final mPerDegLon = 111320.0 * math.cos(meanLat * math.pi / 180.0).abs().clamp(0.2, 1.0);
  var sumSq = 0.0;
  for (final p in samples) {
    final acc = math.max(p.accuracy, 0.1);
    final w = 1.0 / (acc * acc);
    final dy = (p.latitude - meanLat) * mPerDegLat;
    final dx = (p.longitude - meanLon) * mPerDegLon;
    sumSq += w * (dx * dx + dy * dy);
  }
  final sigma = math.sqrt(sumSq / sumW);
  final accuracy = math.max(claimed, sigma);

  return PreciseMarkResult(
    latitude: meanLat,
    longitude: meanLon,
    accuracyMeters: accuracy,
    sampleCount: n,
    altitudeMeters: altW > 0 ? sumAltW / altW : null,
    forced: forced,
  );
}

enum SampleVerdict { accepted, tooInaccurate, jump }

/// Pure (no plugins, no timers) sample bookkeeping for a mark, so the gate
/// can be unit tested.
///
/// Every usable fix (≤ [acceptMeters]) goes into a sliding window of the last
/// [window] samples. The mark has [converged] once the window holds at least
/// [minSamples] and its weighted estimate is ≤ [targetMeters]. Before, each
/// sample had to be ≤ 5 m on its own and the 8 m accept limit was never
/// used, so a phone hovering at 5–10 m outdoors never locked.
class MarkSampler {
  MarkSampler({
    this.acceptMeters = kAcceptAccuracyMeters,
    this.targetMeters = kReadyAccuracyMeters,
    this.minSamples = kMinGoodSamples,
    this.window = kSampleWindow,
  });

  final double acceptMeters;
  final double targetMeters;
  final int minSamples;
  final int window;

  final List<Position> _samples = [];
  Position? _best;

  /// Accepted samples currently in the window (oldest first).
  List<Position> get samples => List.unmodifiable(_samples);

  /// Lowest-accuracy fix seen, usable or not.
  Position? get best => _best;

  /// Weighted estimate over the window, or null when empty.
  PreciseMarkResult? estimate({bool forced = false}) =>
      _samples.isEmpty ? null : averageSamples(_samples, forced: forced);

  bool get converged {
    if (_samples.length < minSamples) return false;
    return estimate()!.accuracyMeters <= targetMeters;
  }

  /// Track [p] as a best-fix candidate without adding it to the window
  /// (used during warm-up).
  void observe(Position p) {
    if (p.accuracy.isFinite &&
        p.accuracy > 0 &&
        (_best == null || p.accuracy < _best!.accuracy)) {
      _best = p;
    }
  }

  SampleVerdict add(Position p) {
    observe(p);
    if (!isFixUsable(p, maxAccuracyMeters: acceptMeters)) {
      return SampleVerdict.tooInaccurate;
    }
    final mean = estimate();
    if (mean != null) {
      final jump = Geolocator.distanceBetween(
        mean.latitude,
        mean.longitude,
        p.latitude,
        p.longitude,
      );
      if (jump > math.max(25.0, p.accuracy * 3)) return SampleVerdict.jump;
    }
    _samples.add(p);
    if (_samples.length > window) _samples.removeAt(0);
    return SampleVerdict.accepted;
  }

  /// Best available result when time runs out: the weighted window if it has
  /// anything, else the single best fix seen. Always marked forced
  /// (provisional). Null when nothing at all arrived.
  PreciseMarkResult? provisional() {
    final est = estimate(forced: true);
    if (est != null) return est;
    final b = _best;
    if (b == null || !b.latitude.isFinite || !b.longitude.isFinite) return null;
    return averageSamples([b], forced: true);
  }

  /// Live progress line while converging.
  String progressLabel(Position latest) {
    final est = estimate();
    final buf = StringBuffer(
      'Sampling ${_samples.length}/$minSamples · now ${formatAcc(latest.accuracy)}',
    );
    if (est != null) buf.write(' · avg ${formatAcc(est.accuracyMeters)}');
    return buf.toString();
  }
}

/// Collect samples until the weighted window converges to
/// [kReadyAccuracyMeters], or [timeout]. On timeout returns the best
/// estimate so far as provisional (forced), or null if no fix arrived.
Future<PreciseMarkResult?> collectPreciseMark({
  required void Function(String status, Position? latest) onProgress,
  Duration timeout = kMarkTimeout,
  bool forceWithBest = false,
  GateObserver? onGate,
  @visibleForTesting Stream<Position>? positions,
  @visibleForTesting Future<PreciseAccuracyCheck> Function()? checkAccuracy,
  @visibleForTesting Duration warmup = kWarmupIgnore,
}) async {
  final accuracyCheck = await (checkAccuracy ?? ensurePreciseAccuracy)();
  final accuracyWarning = accuracyCheck.message;
  if (accuracyWarning != null) {
    onProgress(accuracyWarning, null);
  }

  final started = DateTime.now();
  final sampler = MarkSampler();

  final stream = positions ??
      Geolocator.getPositionStream(locationSettings: highAccuracySettings());

  final completer = Completer<PreciseMarkResult?>();
  late StreamSubscription<Position> sub;
  Timer? timeoutTimer;

  void finish(PreciseMarkResult? result) {
    if (completer.isCompleted) return;
    timeoutTimer?.cancel();
    sub.cancel();
    completer.complete(result?.withAccuracyWarning(accuracyWarning));
  }

  // Diagnostics only: report each decision without changing it.
  GateWindow window() => GateWindow(
    count: sampler.samples.length,
    meanAccM: sampler.estimate()?.accuracyMeters,
    bestAccM: sampler.best?.accuracy,
  );
  void gate(String event, Position pos, String reason) =>
      onGate?.call(event, pos, reason, window());

  timeoutTimer = Timer(timeout, () {
    final b = sampler.best;
    if (b != null) {
      gate(
        sampler.samples.isNotEmpty ? 'timeout_provisional_average' : 'timeout_best_single',
        b,
        'timeout ${timeout.inSeconds}s with ${sampler.samples.length} samples',
      );
    }
    finish(sampler.provisional());
  });

  sub = stream.listen((pos) {
    final elapsed = DateTime.now().difference(started);

    // Warm-up: ignore first seconds (often a cached/network jump), but keep
    // the best one in case nothing better ever arrives.
    if (elapsed < warmup) {
      sampler.observe(pos);
      gate('rejected_warmup', pos, 'within first ${warmup.inSeconds}s of mark');
      onProgress('Warming up GPS… ${formatAcc(pos.accuracy)}', pos);
      return;
    }

    final verdict = sampler.add(pos);
    final acc = pos.accuracy.toStringAsFixed(1);
    switch (verdict) {
      case SampleVerdict.accepted:
        gate('accepted', pos, 'accuracy $acc m <= $kAcceptAccuracyMeters m, weight 1/acc²');
      case SampleVerdict.tooInaccurate:
        gate('rejected_unusable', pos, 'accuracy $acc m > $kAcceptAccuracyMeters m or invalid');
      case SampleVerdict.jump:
        gate('rejected_jump', pos, 'too far from current weighted estimate');
    }
    onProgress(sampler.progressLabel(pos), pos);

    if (sampler.converged) {
      onProgress('Locked ${sampler.samples.length} samples', pos);
      gate('locked', pos,
          'weighted estimate ${sampler.estimate()!.accuracyMeters.toStringAsFixed(1)} m <= $kReadyAccuracyMeters m');
      finish(sampler.estimate());
    }
  }, onError: (Object e) {
    onProgress('GPS error: $e', null);
    finish(sampler.provisional());
  });

  return completer.future;
}

String formatAcc(double meters) {
  final ft = meters * 3.280839895;
  if (ft < 10) return '±${ft.toStringAsFixed(1)} ft';
  return '±${ft.round()} ft';
}
