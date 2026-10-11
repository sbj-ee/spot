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

  test('shortest angle', () {
    expect(shortestAngleDelta(10, 30), closeTo(20, 0.01));
    expect(shortestAngleDelta(350, 10), closeTo(20, 0.01));
  });
}
