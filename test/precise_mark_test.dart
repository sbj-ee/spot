import 'package:flutter_test/flutter_test.dart';
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
