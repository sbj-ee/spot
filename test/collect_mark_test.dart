import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:spot/precise_mark.dart';

import 'support/fake_sensors.dart';

const _precise = PreciseAccuracyCheck(PreciseAccuracyOutcome.precise);

/// Runs the collector on [c] with no warm-up and a short real timeout.
Future<PreciseMarkResult?> _collect(
  StreamController<Position> c, {
  bool force = false,
  Duration warmup = Duration.zero,
  PreciseAccuracyCheck check = _precise,
  List<String>? log,
}) => collectPreciseMark(
  onProgress: (status, latest) => log?.add(status),
  positions: c.stream,
  checkAccuracy: () async => check,
  warmup: warmup,
  timeout: const Duration(milliseconds: 80),
  forceWithBest: force,
);

void main() {
  late StreamController<Position> c;
  setUp(() => c = StreamController<Position>());

  test('locks after five good samples and stops listening', () async {
    final log = <String>[];
    final pending = _collect(c, log: log);
    for (var i = 0; i < 5; i++) {
      c.add(fakePosition(lat: 41.8781 + i * 0.00001, accuracy: 3));
    }
    final result = await pending;

    expect(result!.forced, isFalse);
    expect(result.sampleCount, 5);
    expect(result.latitude, closeTo(41.87812, 1e-7));
    expect(result.accuracyWarning, isNull);
    expect(log.last, 'Locked 5 samples');
    expect(c.hasListener, isFalse);
  });

  test('a sample between ready and accept accuracy counts towards the lock', () async {
    final pending = _collect(c);
    c.add(fakePosition(accuracy: 7)); // usable; weighted down, not dropped
    for (var i = 0; i < 4; i++) {
      c.add(fakePosition(accuracy: 4));
    }
    final result = await pending;

    expect(result!.forced, isFalse);
    expect(result.sampleCount, 5);
    expect(result.accuracyMeters, lessThan(kReadyAccuracyMeters));
  });

  test('a jump is dropped and sampling continues to five', () async {
    final pending = _collect(c);
    c.add(fakePosition(lat: 41.8791)); // ~110 m away
    for (var i = 0; i < 5; i++) {
      c.add(fakePosition());
    }
    final result = await pending;

    expect(result!.forced, isFalse);
    expect(result.sampleCount, 5);
    expect(result.latitude, closeTo(41.8781, 1e-7));
  });

  test('timeout with no fixes fails', () async {
    final pending = _collect(c);
    expect(await pending, isNull);
    expect(c.hasListener, isFalse);
  });

  test('timeout with only weak fixes keeps the best one as provisional', () async {
    final pending = _collect(c);
    c.add(fakePosition(accuracy: 30));
    c.add(fakePosition(accuracy: 20));
    c.add(fakePosition(accuracy: 40));
    final result = await pending;

    expect(result!.forced, isTrue);
    expect(result.sampleCount, 1);
    expect(result.accuracyMeters, 20);
  });

  test('timeout accepts a single fix within accept accuracy', () async {
    final pending = _collect(c);
    c.add(fakePosition(accuracy: 7));
    final result = await pending;

    expect(result!.forced, isTrue);
    expect(result.accuracyMeters, closeTo(7, 1e-9));
  });

  test('timeout averages the window as provisional', () async {
    final pending = _collect(c);
    c.add(fakePosition(accuracy: 3));
    c.add(fakePosition(accuracy: 4));
    final result = await pending;

    expect(result!.forced, isTrue);
    expect(result.sampleCount, 2);
  });

  test('warm-up fixes never lock; the best one is the fallback', () async {
    final log = <String>[];
    final pending = _collect(c, warmup: const Duration(hours: 1), log: log);
    for (var i = 0; i < 5; i++) {
      c.add(fakePosition(accuracy: 3));
    }
    final result = await pending;

    expect(result!.forced, isTrue);
    expect(result.sampleCount, 1);
    expect(log, everyElement(startsWith('Warming up GPS…')));
  });

  test('approximate-location warning is reported and attached', () async {
    const warning = 'Approximate location only.';
    final log = <String>[];
    final pending = _collect(
      c,
      check: const PreciseAccuracyCheck(PreciseAccuracyOutcome.reduced, warning),
      log: log,
    );
    for (var i = 0; i < 5; i++) {
      c.add(fakePosition());
    }
    final result = await pending;

    expect(log.first, warning);
    expect(result!.accuracyWarning, warning);
  });

  test('stream error with no samples fails; with samples keeps them', () async {
    var pending = _collect(c);
    c.addError(StateError('gps off'));
    expect(await pending, isNull);

    c = StreamController<Position>();
    pending = _collect(c);
    c.add(fakePosition());
    c.addError(StateError('gps off'));
    final result = await pending;
    expect(result!.forced, isTrue);
    expect(result.sampleCount, 1);
  });
}
