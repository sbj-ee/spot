import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Accuracy milestones reported as time-to-reach, in feet.
const List<int> kMilestoneFeet = [50, 30, 15, 10, 5];

const double _ftPerM = 3.280839895;

/// Kinds of logged events.
enum DiagKind { session, fix, gate, milestone, ab, note }

/// One row in the diagnostics log. Every row has the same columns so CSV
/// stays flat; fields that don't apply are null.
class DiagEvent {
  DiagEvent({
    required this.at,
    required this.kind,
    required this.sinceSessionMs,
    this.event,
    this.reason,
    this.lat,
    this.lon,
    this.accuracyM,
    this.altitudeM,
    this.speedMps,
    this.bearingDeg,
    this.fixTime,
    this.satsUsed,
    this.satsVisible,
    this.isMocked,
    this.provider,
    this.windowCount,
    this.windowMeanAccM,
    this.bestAccM,
    this.distToSpotM,
    this.abPhase,
  });

  final DateTime at;
  final DiagKind kind;
  final int sinceSessionMs;

  /// Short machine label, e.g. `accepted`, `rejected_jump`, `ttff`.
  final String? event;

  /// Human explanation (why a gate decision was made).
  final String? reason;
  final double? lat;
  final double? lon;
  final double? accuracyM;
  final double? altitudeM;
  final double? speedMps;
  final double? bearingDeg;
  final DateTime? fixTime;
  final int? satsUsed;
  final int? satsVisible;
  final bool? isMocked;
  final String? provider;
  final int? windowCount;
  final double? windowMeanAccM;
  final double? bestAccM;
  final double? distToSpotM;
  final String? abPhase;

  static const List<String> columns = [
    'time',
    'since_session_ms',
    'kind',
    'event',
    'reason',
    'lat',
    'lon',
    'accuracy_m',
    'accuracy_ft',
    'altitude_m',
    'speed_mps',
    'bearing_deg',
    'fix_time',
    'sats_used',
    'sats_visible',
    'is_mocked',
    'provider',
    'window_count',
    'window_mean_acc_m',
    'best_acc_m',
    'dist_to_spot_m',
    'dist_to_spot_ft',
    'ab_phase',
  ];

  Map<String, Object?> toJson() => {
    'time': at.toIso8601String(),
    'since_session_ms': sinceSessionMs,
    'kind': kind.name,
    'event': event,
    'reason': reason,
    'lat': lat,
    'lon': lon,
    'accuracy_m': accuracyM,
    'accuracy_ft': accuracyM == null ? null : accuracyM! * _ftPerM,
    'altitude_m': altitudeM,
    'speed_mps': speedMps,
    'bearing_deg': bearingDeg,
    'fix_time': fixTime?.toIso8601String(),
    'sats_used': satsUsed,
    'sats_visible': satsVisible,
    'is_mocked': isMocked,
    'provider': provider,
    'window_count': windowCount,
    'window_mean_acc_m': windowMeanAccM,
    'best_acc_m': bestAccM,
    'dist_to_spot_m': distToSpotM,
    'dist_to_spot_ft': distToSpotM == null ? null : distToSpotM! * _ftPerM,
    'ab_phase': abPhase,
  };
}

/// Snapshot of the mark averaging window, passed with gate decisions.
class GateWindow {
  const GateWindow({required this.count, this.meanAccM, this.bestAccM});
  final int count;
  final double? meanAccM;
  final double? bestAccM;
}

/// Receives each gate decision from the mark collector.
typedef GateObserver =
    void Function(String event, Position pos, String reason, GateWindow window);

/// In-memory diagnostics log. Off by default; while disabled every record
/// call is a no-op, so normal use pays nothing.
class DiagnosticsLog extends ChangeNotifier {
  DiagnosticsLog({this.maxEvents = 50000, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final DiagnosticsLog instance = DiagnosticsLog();
  static const prefKey = 'diag.enabled';

  final int maxEvents;
  final DateTime Function() _clock;
  final List<DiagEvent> _events = [];

  bool _enabled = false;
  DateTime _sessionStart = DateTime.now();
  DateTime? _firstFixAt;
  final Map<int, Duration> _milestones = {};
  double? _bestAccM;

  /// Device / provider context (from [DiagPlatform]); included in exports.
  Map<String, Object?> deviceInfo = {};

  /// Effective Android provider for this build's location request.
  String? provider;

  /// Most recent live fix (for the diagnostics screen).
  Position? lastFix;

  /// Saved spot the A/B distance error is measured against.
  double? spotLat;
  double? spotLon;

  void setSpot(double? lat, double? lon) {
    spotLat = lat;
    spotLon = lon;
    notifyListeners();
  }

  /// Distance from [p] to the saved spot, or null without a spot.
  double? distanceToSpot(Position? p) {
    if (p == null || spotLat == null || spotLon == null) return null;
    return Geolocator.distanceBetween(spotLat!, spotLon!, p.latitude, p.longitude);
  }

  /// A/B walk test state.
  bool abActive = false;
  String abPhase = 'off';

  bool get enabled => _enabled;
  List<DiagEvent> get events => List.unmodifiable(_events);
  DateTime get sessionStart => _sessionStart;
  Duration? get timeToFirstFix => _firstFixAt?.difference(_sessionStart);
  Map<int, Duration> get milestones => Map.unmodifiable(_milestones);
  double? get bestAccuracyM => _bestAccM;

  Future<void> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefKey) ?? false;
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, on);
    if (on && !_enabled) {
      _enabled = true;
      startSession('diagnostics enabled');
    } else {
      _enabled = on;
    }
    notifyListeners();
  }

  /// Reset TTFF/milestones. Called when the live GPS stream (re)starts.
  void startSession(String why) {
    _sessionStart = _clock();
    _firstFixAt = null;
    _milestones.clear();
    _bestAccM = null;
    if (!_enabled) return;
    _add(DiagEvent(
      at: _sessionStart,
      kind: DiagKind.session,
      sinceSessionMs: 0,
      event: 'session_start',
      reason: why,
      provider: provider,
    ));
  }

  void clear() {
    _events.clear();
    startSession('log cleared');
    notifyListeners();
  }

  int _since(DateTime t) => t.difference(_sessionStart).inMilliseconds;

  void _add(DiagEvent e) {
    _events.add(e);
    if (_events.length > maxEvents) _events.removeAt(0);
  }

  static int? _intOrNull(double v) => v > 0 ? v.round() : null;

  /// Log one live fix. [spot] is the saved spot (for A/B distance error).
  void recordFix(Position p) {
    lastFix = p;
    if (!_enabled) return;
    final now = _clock();
    int? used;
    int? visible;
    if (p is AndroidPosition) {
      used = _intOrNull(p.satellitesUsedInFix);
      visible = _intOrNull(p.satelliteCount);
    }
    final dist = distanceToSpot(p);
    _add(DiagEvent(
      at: now,
      kind: DiagKind.fix,
      sinceSessionMs: _since(now),
      lat: p.latitude,
      lon: p.longitude,
      accuracyM: p.accuracy,
      altitudeM: p.altitude,
      speedMps: p.speed,
      bearingDeg: p.heading,
      fixTime: p.timestamp,
      satsUsed: used,
      satsVisible: visible,
      isMocked: p.isMocked,
      provider: provider,
      distToSpotM: abActive ? dist : null,
      abPhase: abActive ? abPhase : null,
    ));

    if (p.accuracy > 0 && p.accuracy.isFinite) {
      _firstFixAt ??= now;
      if (_firstFixAt == now) {
        _milestone(now, 'ttff', 'first fix ±${(p.accuracy * _ftPerM).round()} ft');
      }
      if (_bestAccM == null || p.accuracy < _bestAccM!) _bestAccM = p.accuracy;
      final ft = p.accuracy * _ftPerM;
      for (final m in kMilestoneFeet) {
        if (ft <= m && !_milestones.containsKey(m)) {
          _milestones[m] = now.difference(_sessionStart);
          _milestone(now, 'reached_${m}ft', 'first fix at or under $m ft');
        }
      }
    }
    notifyListeners();
  }

  void _milestone(DateTime now, String event, String reason) {
    _add(DiagEvent(
      at: now,
      kind: DiagKind.milestone,
      sinceSessionMs: _since(now),
      event: event,
      reason: reason,
    ));
  }

  /// Gate decision from the mark collector.
  void recordGate(String event, Position p, String reason, GateWindow w) {
    if (!_enabled) return;
    final now = _clock();
    _add(DiagEvent(
      at: now,
      kind: DiagKind.gate,
      sinceSessionMs: _since(now),
      event: event,
      reason: reason,
      lat: p.latitude,
      lon: p.longitude,
      accuracyM: p.accuracy,
      fixTime: p.timestamp,
      windowCount: w.count,
      windowMeanAccM: w.meanAccM,
      bestAccM: w.bestAccM,
    ));
    notifyListeners();
  }

  /// Free-form note (mark start/result, A/B checkpoints).
  void note(String event, String reason, {DiagKind kind = DiagKind.note,
      double? lat, double? lon, double? accuracyM, double? distToSpotM}) {
    if (!_enabled) return;
    final now = _clock();
    _add(DiagEvent(
      at: now,
      kind: kind,
      sinceSessionMs: _since(now),
      event: event,
      reason: reason,
      lat: lat,
      lon: lon,
      accuracyM: accuracyM,
      distToSpotM: distToSpotM,
      abPhase: kind == DiagKind.ab ? abPhase : null,
    ));
    notifyListeners();
  }

  void setAbPhase(String phase, {String? reason, double? lat, double? lon,
      double? accuracyM, double? distToSpotM}) {
    abPhase = phase;
    abActive = phase != 'off';
    // Log even the 'off' transition.
    if (_enabled) {
      final now = _clock();
      _add(DiagEvent(
        at: now,
        kind: DiagKind.ab,
        sinceSessionMs: _since(now),
        event: 'ab_$phase',
        reason: reason,
        lat: lat,
        lon: lon,
        accuracyM: accuracyM,
        distToSpotM: distToSpotM,
        abPhase: phase,
      ));
    }
    notifyListeners();
  }

  /// A/B summary: distance error stats for fixes logged while back at A.
  Map<String, Object?> abSummary() {
    final back = _events
        .where((e) => e.kind == DiagKind.fix && e.abPhase == 'back_at_a' && e.distToSpotM != null)
        .map((e) => e.distToSpotM!)
        .toList();
    if (back.isEmpty) return {'back_at_a_fixes': 0};
    back.sort();
    final mean = back.reduce((a, b) => a + b) / back.length;
    return {
      'back_at_a_fixes': back.length,
      'error_mean_m': mean,
      'error_median_m': back[back.length ~/ 2],
      'error_max_m': back.last,
      'error_mean_ft': mean * _ftPerM,
    };
  }

  Map<String, Object?> summary() => {
    'session_start': _sessionStart.toIso8601String(),
    'provider': provider,
    'time_to_first_fix_ms': timeToFirstFix?.inMilliseconds,
    'time_to_accuracy_ms': {
      for (final m in kMilestoneFeet) '${m}ft': _milestones[m]?.inMilliseconds,
    },
    'best_accuracy_m': _bestAccM,
    'event_count': _events.length,
    'ab': abSummary(),
  };

  String toJsonString({Map<String, Object?> app = const {}}) {
    return const JsonEncoder.withIndent(' ').convert({
      'app': app,
      'device': deviceInfo,
      'summary': summary(),
      'events': [for (final e in _events) e.toJson()],
    });
  }

  String toCsv() {
    final b = StringBuffer()..writeln(DiagEvent.columns.join(','));
    for (final e in _events) {
      final j = e.toJson();
      b.writeln(DiagEvent.columns.map((c) => _csvCell(j[c])).join(','));
    }
    return b.toString();
  }

  static String _csvCell(Object? v) {
    if (v == null) return '';
    if (v is double) {
      if (!v.isFinite) return '';
      return v.toString();
    }
    final s = v.toString();
    if (s.contains(RegExp(r'[",\n\r]'))) return '"${s.replaceAll('"', '""')}"';
    return s;
  }
}
