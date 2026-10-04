import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spot/diag_platform.dart';
import 'package:spot/diagnostics.dart';
import 'package:spot/home_screen.dart';
import 'package:spot/precise_mark.dart';
import 'package:spot/version.dart';

import 'support/fake_sensors.dart';

const _lat = 41.8781;
const _lon = -87.6298;
const _m = 1 / 111320.0;

AndroidPosition _ap(double acc, {double northM = 0, double used = 9, double visible = 31}) =>
    AndroidPosition(
      latitude: _lat + northM * _m,
      longitude: _lon,
      timestamp: DateTime.now(),
      accuracy: acc,
      altitude: 180.0,
      altitudeAccuracy: 2.0,
      heading: 90.0,
      headingAccuracy: 5.0,
      speed: 1.2,
      speedAccuracy: 0.3,
      satelliteCount: visible,
      satellitesUsedInFix: used,
    );

class _Clock {
  DateTime now = DateTime(2026, 10, 4, 12);
  DateTime call() => now;
  void advance(int ms) => now = now.add(Duration(milliseconds: ms));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('version constant matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(kAppVersion, v);
  });

  group('DiagnosticsLog', () {
    test('off by default and records nothing while off', () async {
      final log = DiagnosticsLog();
      await log.loadEnabled();
      expect(log.enabled, isFalse);
      log.recordFix(_ap(4));
      log.recordGate('accepted', _ap(4), 'x', const GateWindow(count: 1));
      log.note('mark_start', 'x');
      expect(log.events, isEmpty);
      expect(log.lastFix, isNotNull);
    });

    test('enabled state persists', () async {
      await DiagnosticsLog().setEnabled(true);
      final again = DiagnosticsLog();
      await again.loadEnabled();
      expect(again.enabled, isTrue);
    });

    test('fix rows carry sats, speed, bearing; TTFF and milestones', () async {
      final clock = _Clock();
      final log = DiagnosticsLog(clock: clock.call);
      await log.setEnabled(true);
      log.startSession('test');
      clock.advance(3000);
      log.recordFix(_ap(20)); // 66 ft
      clock.advance(2000);
      log.recordFix(_ap(9)); // 29.5 ft -> 50 and 30
      clock.advance(5000);
      log.recordFix(_ap(1.4)); // 4.6 ft -> 15, 10, 5
      expect(log.timeToFirstFix, const Duration(seconds: 3));
      expect(log.milestones[50], const Duration(seconds: 5));
      expect(log.milestones[30], const Duration(seconds: 5));
      expect(log.milestones[15], const Duration(seconds: 10));
      expect(log.milestones[5], const Duration(seconds: 10));
      final fix = log.events.firstWhere((e) => e.kind == DiagKind.fix);
      expect(fix.satsUsed, 9);
      expect(fix.satsVisible, 31);
      expect(fix.speedMps, 1.2);
      expect(fix.bearingDeg, 90);
      expect(
        log.events.where((e) => e.kind == DiagKind.milestone).map((e) => e.event),
        ['ttff', 'reached_50ft', 'reached_30ft', 'reached_15ft', 'reached_10ft', 'reached_5ft'],
      );
    });

    test('CSV has header, one row per event, escapes commas', () async {
      final log = DiagnosticsLog();
      await log.setEnabled(true);
      log.recordFix(_ap(4));
      log.note('x', 'a, "quoted" reason');
      final lines = const LineSplitter().convert(log.toCsv());
      expect(lines.first, DiagEvent.columns.join(','));
      expect(lines.length, log.events.length + 1);
      expect(lines.last, contains('"a, ""quoted"" reason"'));
    });

    test('JSON export parses and includes summary and device', () async {
      final log = DiagnosticsLog()..deviceInfo = {'model': 'Pixel 9 Pro XL'};
      await log.setEnabled(true);
      log.recordFix(_ap(4));
      final j = jsonDecode(log.toJsonString(app: {'version': kAppVersion})) as Map;
      expect(j['app']['version'], kAppVersion);
      expect(j['device']['model'], 'Pixel 9 Pro XL');
      expect(j['summary']['time_to_first_fix_ms'], isNotNull);
      expect((j['events'] as List).length, log.events.length);
    });

    test('A/B logs distance error vs saved spot', () async {
      final log = DiagnosticsLog();
      await log.setEnabled(true);
      log.setSpot(_lat, _lon);
      log.setAbPhase('at_a');
      log.recordFix(_ap(4));
      log.setAbPhase('at_b');
      log.recordFix(_ap(4, northM: 30));
      log.setAbPhase('back_at_a');
      log.recordFix(_ap(4, northM: 2));
      log.recordFix(_ap(4, northM: 4));
      final fixes = log.events.where((e) => e.kind == DiagKind.fix).toList();
      expect(fixes[1].distToSpotM, closeTo(30, 0.2));
      final s = log.abSummary();
      expect(s['back_at_a_fixes'], 2);
      expect(s['error_mean_m'] as double, closeTo(3, 0.1));
      log.setAbPhase('off');
      log.recordFix(_ap(4));
      expect(log.events.last.distToSpotM, isNull);
    });
  });

  test('effectiveProvider mirrors geolocator_android 5.x', () {
    expect(
      DiagPlatform.effectiveProvider(
        forceLocationManager: true,
        info: {'sdk_int': 35, 'enabled_providers': ['passive', 'gps', 'network', 'fused']},
      ),
      'LocationManager:fused',
    );
    expect(
      DiagPlatform.effectiveProvider(
        forceLocationManager: true,
        info: {'sdk_int': 30, 'enabled_providers': ['gps', 'fused']},
      ),
      'LocationManager:gps',
    );
    expect(
      DiagPlatform.effectiveProvider(forceLocationManager: false, info: const {}),
      startsWith('play_services_fused'),
    );
  });

  test('gate decisions are reported, baseline gate unchanged', () async {
    final c = StreamController<Position>();
    final events = <String>[];
    final f = collectPreciseMark(
      onProgress: (_, _) {},
      onGate: (e, _, _, _) => events.add(e),
      positions: c.stream,
      checkAccuracy: () async =>
          const PreciseAccuracyCheck(PreciseAccuracyOutcome.precise),
      warmup: Duration.zero,
      timeout: const Duration(milliseconds: 300),
    );
    c.add(_ap(9)); // > 8 m accept limit
    c.add(_ap(6)); // usable but > 5 m: never averaged (baseline behaviour)
    c.add(_ap(4));
    c.add(_ap(4, northM: 80)); // jump
    final r = await f;
    expect(events, [
      'rejected_unusable',
      'ignored_above_ready',
      'accepted',
      'rejected_jump',
      'timeout_best_single',
    ]);
    expect(r!.forced, isTrue);
    expect(r.sampleCount, 1);
    await c.close();
  });

  testWidgets('settings toggle reveals the DIAG screen', (tester) async {
    final log = DiagnosticsLog();
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(sensors: FakeSensors(), diagnostics: log),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('openDiagnostics')), findsNothing);

    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('diagToggle')));
    expect(toggle.value, isFalse);
    await tester.tap(find.byKey(const Key('diagToggle')));
    await tester.pumpAndSettle();
    expect(log.enabled, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('openDiagnostics')), findsOneWidget);
    await tester.tap(find.byKey(const Key('openDiagnostics')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('A/B walk test'), 200);
    expect(find.text('A/B walk test'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Export CSV'), 200);
    expect(find.text('Export CSV'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
