import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spot/spot_store.dart';

void main() {
  final spot = SavedSpot(
    latitude: 41.8781,
    longitude: -87.6298,
    accuracyMeters: 4,
    markedAt: DateTime.utc(2026, 10, 11, 12),
    altitudeMeters: 180,
  );

  test('save writes one key and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SpotStore();
    await store.save(spot);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'spot.v1'});

    final loaded = await store.load();
    expect(loaded!.latitude, spot.latitude);
    expect(loaded.longitude, spot.longitude);
    expect(loaded.accuracyMeters, spot.accuracyMeters);
    expect(loaded.markedAt, spot.markedAt);
    expect(loaded.altitudeMeters, spot.altitudeMeters);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('migrates the per-field v0 layout', () async {
    SharedPreferences.setMockInitialValues({
      'spot.v0.lat': 41.8781,
      'spot.v0.lon': -87.6298,
      'spot.v0.acc': 4.0,
      'spot.v0.at': '2026-10-11T12:00:00.000Z',
    });
    final loaded = await SpotStore().load();
    expect(loaded!.latitude, 41.8781);
    expect(loaded.altitudeMeters, isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'spot.v1'});
  });

  test('corrupt entry loads as no spot', () async {
    SharedPreferences.setMockInitialValues({'spot.v1': '{not json'});
    expect(await SpotStore().load(), isNull);
    SharedPreferences.setMockInitialValues({'spot.v1': jsonEncode([1, 2])});
    expect(await SpotStore().load(), isNull);
  });
}
