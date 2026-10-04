import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:spot/home_screen.dart';
import 'package:spot/precise_mark.dart';

const _lat = 41.8781;
const _lon = -87.6298;

/// ~1 m of latitude in degrees.
const _m = 1 / 111320.0;

Position _p(double accuracy, {double northM = 0, double? altitude}) => Position(
  latitude: _lat + northM * _m,
  longitude: _lon,
  timestamp: DateTime.now(),
  accuracy: accuracy,
  altitude: altitude ?? 180,
  altitudeAccuracy: 2,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  group('highAccuracySettings', () {
    test('fused high accuracy, 1 s, no distance filter', () {
      final s = highAccuracySettings() as AndroidSettings;
      expect(s.forceLocationManager, isFalse);
      expect(s.distanceFilter, 0);
      expect(s.intervalDuration, const Duration(seconds: 1));
      // Android maps high/best/bestForNavigation to PRIORITY_HIGH_ACCURACY.
      expect(
        s.accuracy.index,
        greaterThanOrEqualTo(LocationAccuracy.high.index),
      );
    });
  });

  group('averageSamples', () {
    test('weights by 1/accuracy²', () {
      // 3 m at 0, 9 m at +9 m: weights 1/9 vs 1/81 -> mean at 0.9 m.
      final r = averageSamples([_p(3), _p(9, northM: 9)], forced: false);
      expect((r.latitude - _lat) / _m, closeTo(0.9, 0.01));
    });

    test('equal accuracies: plain mean, accuracy = claimed', () {
      final r = averageSamples([_p(4), _p(4), _p(4)], forced: false);
      expect(r.latitude, closeTo(_lat, 1e-12));
      expect(r.accuracyMeters, closeTo(4, 1e-9));
      expect(r.sampleCount, 3);
    });

    test('does not claim √N improvement', () {
      final r = averageSamples(List.generate(10, (_) => _p(4)), forced: false);
      expect(r.accuracyMeters, closeTo(4, 1e-9));
    });

    test('scatter dominates when it exceeds claimed accuracy', () {
      final r = averageSamples(
        [_p(2, northM: -10), _p(2, northM: 10)],
        forced: false,
      );
      expect(r.accuracyMeters, closeTo(10, 0.05));
    });

    test('one weak sample does not dominate', () {
      final r = averageSamples([_p(4), _p(4), _p(4), _p(4), _p(12)], forced: false);
      // Old code reported the worst sample (12 m).
      expect(r.accuracyMeters, lessThan(5));
    });
  });

  group('MarkSampler gate', () {
    test('steady 4 m outdoors locks after 5 samples', () {
      final s = MarkSampler();
      for (var i = 0; i < 4; i++) {
        expect(s.add(_p(4)), SampleVerdict.accepted);
        expect(s.converged, isFalse);
      }
      s.add(_p(4));
      expect(s.converged, isTrue);
      expect(s.estimate()!.accuracyMeters, closeTo(4, 1e-9));
    });

    test('mix of 4-6 m locks (old gate needed every sample ≤ 5 m)', () {
      final s = MarkSampler();
      for (final a in [4.0, 6.0, 4.5, 5.5, 4.0, 6.0]) {
        s.add(_p(a));
      }
      expect(s.samples.length, 6);
      expect(s.converged, isTrue);
    });

    test('stuck at 9 m (≈30 ft) never locks, but is kept', () {
      final s = MarkSampler();
      for (var i = 0; i < 20; i++) {
        s.add(_p(9.1));
      }
      expect(s.converged, isFalse);
      expect(s.samples.length, kSampleWindow);
      final r = s.provisional()!;
      expect(r.forced, isTrue);
      expect(r.accuracyMeters, closeTo(9.1, 1e-6));
      expect(r.sampleCount, kSampleWindow);
    });

    test('rejects samples worse than accept limit', () {
      final s = MarkSampler();
      expect(s.add(_p(kAcceptAccuracyMeters + 0.1)), SampleVerdict.tooInaccurate);
      expect(s.add(_p(0)), SampleVerdict.tooInaccurate);
      expect(s.add(_p(double.nan)), SampleVerdict.tooInaccurate);
      expect(s.samples, isEmpty);
    });

    test('rejects a jump far from the current estimate', () {
      final s = MarkSampler()
        ..add(_p(4))
        ..add(_p(4));
      expect(s.add(_p(4, northM: 60)), SampleVerdict.jump);
      expect(s.add(_p(4, northM: 3)), SampleVerdict.accepted);
    });

    test('window slides: early poor fixes age out as the fix improves', () {
      final s = MarkSampler();
      for (var i = 0; i < 10; i++) {
        s.add(_p(12));
      }
      expect(s.converged, isFalse);
      for (var i = 0; i < 9; i++) {
        s.add(_p(3.5));
      }
      expect(s.converged, isTrue);
    });

    test('provisional falls back to best single fix when none usable', () {
      final s = MarkSampler()
        ..add(_p(40))
        ..add(_p(25));
      expect(s.samples, isEmpty);
      final r = s.provisional()!;
      expect(r.accuracyMeters, 25);
      expect(r.sampleCount, 1);
      expect(r.forced, isTrue);
    });

    test('observe tracks best without adding to window', () {
      final s = MarkSampler()..observe(_p(3));
      expect(s.samples, isEmpty);
      expect(s.best!.accuracy, 3);
    });

    test('nothing seen: provisional is null', () {
      expect(MarkSampler().provisional(), isNull);
    });

    test('progress label shows live and averaged accuracy', () {
      final s = MarkSampler()..add(_p(6));
      expect(s.progressLabel(_p(6)), 'Sampling 1/5 · now ±20 ft · avg ±20 ft');
    });
  });

  group('collectPreciseMark', () {
    Future<PreciseAccuracyCheck> precise() async =>
        const PreciseAccuracyCheck(PreciseAccuracyOutcome.precise);

    test('locks without waiting for timeout on good fixes', () async {
      final c = StreamController<Position>();
      final msgs = <String>[];
      final f = collectPreciseMark(
        onProgress: (m, _) => msgs.add(m),
        positions: c.stream,
        checkAccuracy: precise,
        warmup: Duration.zero,
        timeout: const Duration(seconds: 30),
      );
      for (final a in [4.0, 5.5, 4.2, 4.8, 4.0]) {
        c.add(_p(a));
      }
      final r = await f;
      expect(r, isNotNull);
      expect(r!.forced, isFalse);
      expect(r.sampleCount, 5);
      expect(msgs.last, startsWith('Locked'));
      await c.close();
    });

    test('timeout returns provisional averaged fix', () async {
      final c = StreamController<Position>();
      final f = collectPreciseMark(
        onProgress: (_, _) {},
        positions: c.stream,
        checkAccuracy: precise,
        warmup: Duration.zero,
        timeout: const Duration(milliseconds: 200),
      );
      for (var i = 0; i < 6; i++) {
        c.add(_p(9.1));
      }
      final r = await f;
      expect(r, isNotNull);
      expect(r!.forced, isTrue);
      expect(r.sampleCount, 6);
      expect(r.accuracyMeters, closeTo(9.1, 1e-6));
      await c.close();
    });

    test('timeout with no fixes returns null', () async {
      final c = StreamController<Position>();
      final r = await collectPreciseMark(
        onProgress: (_, _) {},
        positions: c.stream,
        checkAccuracy: precise,
        timeout: const Duration(milliseconds: 50),
      );
      expect(r, isNull);
      await c.close();
    });
  });

  group('liveFixStatus', () {
    test('tiers', () {
      expect(liveFixStatus(4), startsWith('Ready'));
      expect(liveFixStatus(9.1), 'Converging · ±30 ft');
      expect(liveFixStatus(20), startsWith('Waiting for better fix'));
    });
  });
}
