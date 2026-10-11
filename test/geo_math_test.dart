import 'package:flutter_test/flutter_test.dart';
import 'package:spot/geo_math.dart';

void main() {
  test('distance formatting', () {
    expect(formatDistance(3), '9.8 ft');
    expect(formatDistance(100), '328 ft');
    expect(formatDistance(1000).contains('mi'), isTrue);
  });

  test('arrival radius is combined accuracy within 6–20 m', () {
    expect(arrivalRadiusMeters(1, 1), 6);
    expect(arrivalRadiusMeters(4, 5), 9);
    expect(arrivalRadiusMeters(50, 5), 20);
    expect(arrivalRadiusMeters(double.nan, 5), 20);
  });

  test('heading smoothing takes the short way across north', () {
    expect(smoothHeading(null, -90), 270);
    expect(smoothHeading(350, 10, alpha: 0.5), closeTo(0, 0.01));
    expect(smoothHeading(10, 350, alpha: 0.5), closeTo(0, 0.01));
    expect(smoothHeading(100, 120, alpha: 0.25), closeTo(105, 0.01));
  });

  test('course over ground needs walking speed and a valid course', () {
    expect(courseOverGround(speedMps: 0.3, headingDeg: 90), isNull);
    expect(courseOverGround(speedMps: 1.5, headingDeg: -1), isNull);
    expect(courseOverGround(speedMps: 1.5, headingDeg: double.nan), isNull);
    expect(courseOverGround(speedMps: 1.5, headingDeg: 90), 90);
  });

  test('shortest angle', () {
    expect(shortestAngleDelta(10, 30), closeTo(20, 0.01));
    expect(shortestAngleDelta(350, 10), closeTo(20, 0.01));
  });
}
