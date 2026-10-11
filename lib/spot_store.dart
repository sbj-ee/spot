import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SavedSpot {
  const SavedSpot({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.markedAt,
    this.altitudeMeters,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime markedAt;
  final double? altitudeMeters;

  Map<String, Object?> toJson() => {
        'lat': latitude,
        'lon': longitude,
        'acc': accuracyMeters,
        'at': markedAt.toIso8601String(),
        'alt': altitudeMeters,
      };

  static SavedSpot? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    final lat = json['lat'];
    final lon = json['lon'];
    final acc = json['acc'];
    final at = json['at'];
    if (lat is! num || lon is! num || acc is! num || at is! String) return null;
    return SavedSpot(
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      accuracyMeters: acc.toDouble(),
      markedAt: DateTime.tryParse(at) ?? DateTime.now(),
      altitudeMeters: (json['alt'] is num) ? (json['alt'] as num).toDouble() : null,
    );
  }
}

class SpotStore {
  /// Whole spot as one JSON string, so a save is a single atomic write and
  /// can never pair a new latitude with an old longitude.
  static const _key = 'spot.v1';

  /// Pre-0.1.2 layout: one pref per field. Read once, then migrated.
  static const _legacyKey = 'spot.v0';
  static const _legacyFields = ['lat', 'lon', 'acc', 'at', 'alt'];

  Future<SavedSpot?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, Object?>) return SavedSpot.fromJson(json);
      } on FormatException {
        // Corrupt entry: treat as no spot.
      }
      return null;
    }

    final lat = prefs.getDouble('$_legacyKey.lat');
    final lon = prefs.getDouble('$_legacyKey.lon');
    final acc = prefs.getDouble('$_legacyKey.acc');
    final at = prefs.getString('$_legacyKey.at');
    if (lat == null || lon == null || acc == null || at == null) return null;
    final spot = SavedSpot(
      latitude: lat,
      longitude: lon,
      accuracyMeters: acc,
      markedAt: DateTime.tryParse(at) ?? DateTime.now(),
      altitudeMeters: prefs.getDouble('$_legacyKey.alt'),
    );
    await save(spot);
    return spot;
  }

  Future<void> save(SavedSpot spot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(spot.toJson()));
    await _removeLegacy(prefs);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await _removeLegacy(prefs);
  }

  Future<void> _removeLegacy(SharedPreferences prefs) async {
    for (final field in _legacyFields) {
      await prefs.remove('$_legacyKey.$field');
    }
  }
}
