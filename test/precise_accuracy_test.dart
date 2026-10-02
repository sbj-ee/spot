import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:spot/precise_mark.dart';

void main() {
  group('ensurePreciseAccuracy', () {
    test('precise already: no request', () async {
      var requested = 0;
      final r = await ensurePreciseAccuracy(
        getAccuracy: () async => LocationAccuracyStatus.precise,
        requestTemporaryFullAccuracy: (_) async {
          requested++;
          return LocationAccuracyStatus.precise;
        },
        canRequestTemporary: true,
      );
      expect(r.outcome, PreciseAccuracyOutcome.precise);
      expect(r.message, isNull);
      expect(requested, 0);
    });

    test('iOS reduced: requests with the Info.plist purpose key', () async {
      String? usedKey;
      final r = await ensurePreciseAccuracy(
        getAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: (key) async {
          usedKey = key;
          return LocationAccuracyStatus.precise;
        },
        canRequestTemporary: true,
      );
      expect(usedKey, 'PreciseAccuracy');
      expect(r.outcome, PreciseAccuracyOutcome.upgraded);
      expect(r.isPrecise, isTrue);
    });

    test('iOS reduced and declined: reported, not silent', () async {
      final r = await ensurePreciseAccuracy(
        getAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: (_) async =>
            LocationAccuracyStatus.reduced,
        canRequestTemporary: true,
      );
      expect(r.outcome, PreciseAccuracyOutcome.reduced);
      expect(r.message, isNotNull);
    });

    test('request throws: failure is returned with the error', () async {
      final r = await ensurePreciseAccuracy(
        getAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: (_) async =>
            throw Exception('purpose key not found'),
        canRequestTemporary: true,
      );
      expect(r.outcome, PreciseAccuracyOutcome.failed);
      expect(r.message, contains('purpose key not found'));
    });

    test('Android reduced: reports, does not call iOS-only API', () async {
      var requested = 0;
      final r = await ensurePreciseAccuracy(
        getAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: (_) async {
          requested++;
          return LocationAccuracyStatus.precise;
        },
        canRequestTemporary: false,
      );
      expect(requested, 0);
      expect(r.outcome, PreciseAccuracyOutcome.reduced);
      expect(r.message, contains('Settings'));
    });
  });
}
