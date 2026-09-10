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

  static SavedSpot? fromJson(Map<String, Object>? json) {
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
  static const _key = 'spot.v0';

  Future<SavedSpot?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble('$_key.lat');
    final lon = prefs.getDouble('$_key.lon');
    final acc = prefs.getDouble('$_key.acc');
    final at = prefs.getString('$_key.at');
    if (lat == null || lon == null || acc == null || at == null) return null;
    return SavedSpot(
      latitude: lat,
      longitude: lon,
      accuracyMeters: acc,
      markedAt: DateTime.tryParse(at) ?? DateTime.now(),
      altitudeMeters: prefs.getDouble('$_key.alt'),
    );
  }

  Future<void> save(SavedSpot spot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('$_key.lat', spot.latitude);
    await prefs.setDouble('$_key.lon', spot.longitude);
    await prefs.setDouble('$_key.acc', spot.accuracyMeters);
    await prefs.setString('$_key.at', spot.markedAt.toIso8601String());
    if (spot.altitudeMeters != null) {
      await prefs.setDouble('$_key.alt', spot.altitudeMeters!);
    } else {
      await prefs.remove('$_key.alt');
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_key.lat');
    await prefs.remove('$_key.lon');
    await prefs.remove('$_key.acc');
    await prefs.remove('$_key.at');
    await prefs.remove('$_key.alt');
  }
}
