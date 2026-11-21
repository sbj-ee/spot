import 'package:flutter_test/flutter_test.dart';
import 'package:spot/compass_offset.dart';

/// Feeds [n] walking fixes: GPS course [course], compass [compass].
bool walk(
  CompassOffsetEstimator e,
  int n, {
  double course = 90,
  double compass = 75,
  double speed = 1.4,
  double accuracy = 4,
  double? courseAccuracy,
}) {
  var changed = false;
  for (var i = 0; i < n; i++) {
    changed |= e.addFix(
      courseDeg: course,
      compassTrueDeg: compass,
      speedMps: speed,
      accuracyMeters: accuracy,
      courseAccuracyDeg: courseAccuracy,
    );
  }
  return changed;
}

void main() {
  test('learns a steady 15 deg error from straight walking', () {
    final e = CompassOffsetEstimator();
    expect(walk(e, 4), isFalse, reason: 'needs a full window first');
    expect(walk(e, 1), isTrue);
    expect(e.offsetDeg, closeTo(7.5, 0.01), reason: 'first window: half way');
    walk(e, 50);
    expect(e.offsetDeg, closeTo(15, 0.3));
  });

  test('learns across north and with a negative error', () {
    final e = CompassOffsetEstimator();
    walk(e, 60, course: 355, compass: 7); // compass reads 12 deg clockwise
    expect(e.offsetDeg, closeTo(-12, 0.3));
  });

  test('ignores standing, driving, weak fixes and bad course accuracy', () {
    final e = CompassOffsetEstimator();
    walk(e, 20, speed: 0.4);
    walk(e, 20, speed: 10);
    walk(e, 20, accuracy: 30);
    walk(e, 20, courseAccuracy: 45);
    expect(e.observations, 0);
    walk(e, 5, courseAccuracy: 8);
    expect(e.observations, 1);
  });

  test('ignores a phone not pointing where you walk', () {
    final e = CompassOffsetEstimator();
    walk(e, 20, course: 90, compass: 0); // phone sideways
    expect(e.observations, 0);
  });

  test('a turn inside the window is not an observation', () {
    final e = CompassOffsetEstimator();
    for (final c in [90.0, 90, 120, 150, 180]) {
      e.addFix(
        courseDeg: c,
        compassTrueDeg: c - 10,
        speedMps: 1.4,
        accuracyMeters: 4,
      );
    }
    expect(e.observations, 0);
  });

  test('a gap (no compass or no course) restarts the window', () {
    final e = CompassOffsetEstimator();
    walk(e, 3);
    e.addFix(
      courseDeg: 90,
      compassTrueDeg: null,
      speedMps: 1.4,
      accuracyMeters: 4,
    );
    walk(e, 4);
    expect(e.observations, 0);
    walk(e, 1);
    expect(e.observations, 1);
  });

  test('offset stays within the cap', () {
    final e = CompassOffsetEstimator(maxOffsetDeg: 10);
    walk(e, 100, course: 90, compass: 60);
    expect(e.offsetDeg, 10);
  });
}
