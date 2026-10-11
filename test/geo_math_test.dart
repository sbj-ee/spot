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

  test('fix age switches to days after 24 h', () {
    final now = DateTime.now();
    expect(formatFixAge(now.subtract(const Duration(hours: 5))), '5h ago');
    expect(formatFixAge(now.subtract(const Duration(hours: 72))), '3d ago');
  });

  test('turn description', () {
    expect(turnDescription(5), 'straight ahead');
    expect(turnDescription(-45), 'ahead to your left');
    expect(turnDescription(90), 'to your right');
    expect(turnDescription(-140), 'behind you to your left');
    expect(turnDescription(180), 'behind you');
  });

  test('altitude hint only when clearly beyond vertical error', () {
    String? hint(double? spot, double here, double acc) => altitudeHint(
      spotAltitudeMeters: spot,
      hereAltitudeMeters: here,
      hereAltitudeAccuracyMeters: acc,
    );
    expect(hint(null, 180, 2), isNull);
    expect(hint(184, 180, 2), isNull); // under 6 m
    expect(hint(190, 180, 8), isNull); // under 2x accuracy
    expect(hint(190, 180, 0), isNull); // no vertical accuracy
    expect(hint(190, 180, 2), 'Spot is ~35 ft above you (rough)');
    expect(hint(170, 180, 2), 'Spot is ~35 ft below you (rough)');
  });

  test('shortest angle', () {
    expect(shortestAngleDelta(10, 30), closeTo(20, 0.01));
    expect(shortestAngleDelta(350, 10), closeTo(20, 0.01));
  });
}
