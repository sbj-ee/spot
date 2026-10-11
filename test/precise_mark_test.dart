import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:spot/precise_mark.dart';

import 'support/fake_sensors.dart';

void main() {
  // ~0.001 deg latitude is ~111 m.
  final near = [
    fakePosition(lat: 41.87810),
    fakePosition(lat: 41.87811),
    fakePosition(lat: 41.87809),
    fakePosition(lat: 41.87812),
  ];
  final far = fakePosition(lat: 41.87910);

  test('drops a jump even when it was the first sample', () {
    expect(withoutOutliers([far, ...near]), near);
    expect(withoutOutliers([...near, far]), near);
  });

  test('keeps a tight cluster whole', () {
    expect(withoutOutliers(near), near);
  });

  test('fewer than 3 samples are left alone', () {
    expect(withoutOutliers([far, near.first]), [far, near.first]);
  });

  test('average reports mean position and worst sample accuracy', () {
    final result = averageSamples([
      fakePosition(lat: 41.87810, accuracy: 3),
      fakePosition(lat: 41.87812, accuracy: 5),
    ], forced: false);
    expect(result.latitude, closeTo(41.87811, 1e-9));
    expect(result.longitude, closeTo(-87.6298, 1e-9));
    expect(result.accuracyMeters, 5);
    expect(result.sampleCount, 2);
    expect(result.altitudeMeters, 180);
  });

  test('average accuracy grows to the scatter of the samples', () {
    // Two fixes ~111 m apart, each claiming 3 m: 1-sigma radius ~55 m.
    final result = averageSamples([
      fakePosition(lat: 41.8781, accuracy: 3),
      fakePosition(lat: 41.8791, accuracy: 3),
    ], forced: true);
    expect(result.accuracyMeters, closeTo(55.7, 0.5));
    expect(result.forced, isTrue);
  });

  test('fix sanity checks', () {
    bool usable(Position p) => isFixUsable(p, maxAccuracyMeters: 8);
    expect(usable(fakePosition(accuracy: 8)), isTrue);
    expect(usable(fakePosition(accuracy: 8.1)), isFalse);
    expect(usable(fakePosition(accuracy: 0)), isFalse);
    expect(usable(fakePosition(lat: 91)), isFalse);
    expect(usable(fakePosition(lon: double.nan)), isFalse);
  });

  test('fix with non-finite accuracy is not usable', () {
    expect(
      isFixUsable(
        fakePosition(accuracy: double.nan),
        maxAccuracyMeters: double.infinity,
      ),
      isFalse,
    );
    expect(isFixUsable(fakePosition(), maxAccuracyMeters: 8), isTrue);
  });
}
