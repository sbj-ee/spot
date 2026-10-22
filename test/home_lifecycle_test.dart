import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spot/home_screen.dart';
import 'package:spot/precise_mark.dart';

import 'support/fake_sensors.dart';

Future<void> _background(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
}

Future<void> _foreground(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  await tester.pump();
}

double? _compassHeading(WidgetTester tester) =>
    // ignore: avoid_dynamic_calls
    (tester.state(find.byType(HomeScreen)) as dynamic).compassHeadingDeg
        as double?;

String _storedSpot() => jsonEncode({
  'lat': 41.8781,
  'lon': -87.6298,
  'acc': 4.0,
  'at': DateTime.now().toIso8601String(),
  'alt': null,
});

bool _sensorsActive(WidgetTester tester) =>
    // ignore: avoid_dynamic_calls
    (tester.state(find.byType(HomeScreen)) as dynamic).sensorsActive as bool;

Future<void> _pumpHome(
  WidgetTester tester,
  FakeSensors sensors, {
  PreciseMarkCollector? collect,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(sensors: sensors, collectMark: collect),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Unmount so the 1 s timer is cancelled before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('starts GPS, compass and timer on launch', (tester) async {
    final s = FakeSensors();
    await _pumpHome(tester, s);
    expect(s.positionListening, isTrue);
    expect(s.compassListening, isTrue);
    expect(_sensorsActive(tester), isTrue);

    s.emitPosition(fakePosition(accuracy: 3));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Ready'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('background stops sensors; resume restarts them', (tester) async {
    final s = FakeSensors();
    await _pumpHome(tester, s);

    await _background(tester);
    expect(s.positionListening, isFalse);
    expect(s.compassListening, isFalse);
    expect(s.positionCancels, 1);
    expect(s.compassCancels, 1);
    expect(_sensorsActive(tester), isFalse);

    // Inactive alone (e.g. permission sheet) must not stop anything.
    await _foreground(tester);
    expect(s.positionListening, isTrue);
    expect(s.compassListening, isTrue);
    expect(s.positionListens, 2);
    expect(_sensorsActive(tester), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(s.positionListening, isTrue);
    await _unmount(tester);
  });

  testWidgets('resume re-checks location service after Settings', (
    tester,
  ) async {
    final s = FakeSensors()..serviceEnabled = false;
    await _pumpHome(tester, s);
    expect(find.text('Turn on Location / GPS'), findsOneWidget);
    expect(s.positionListening, isFalse);

    await _background(tester);
    s.serviceEnabled = true; // user turned Location on in Settings
    await _foreground(tester);

    expect(find.text('Turn on Location / GPS'), findsNothing);
    expect(s.positionListening, isTrue);
    s.emitPosition(fakePosition(accuracy: 20));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Waiting for better fix'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'resume re-checks permission without prompting or Settings loop',
    (tester) async {
      final s = FakeSensors()
        ..permission = LocationPermission.denied
        ..permissionAfterRequest = LocationPermission.denied;
      await _pumpHome(tester, s);
      expect(s.requestPermissionCalls, 1); // launch may prompt once
      expect(s.openAppSettingsCalls, 0); // never auto-jumps to Settings
      expect(find.textContaining('permission required'), findsOneWidget);

      await _background(tester);
      await _foreground(tester);
      expect(s.requestPermissionCalls, 1, reason: 'resume must not re-prompt');
      expect(
        s.openAppSettingsCalls,
        0,
        reason: 'resume must not loop to Settings',
      );
      expect(find.textContaining('permission required'), findsOneWidget);

      await _background(tester);
      s.permission = LocationPermission.whileInUse; // granted in Settings
      await _foreground(tester);
      expect(find.textContaining('permission required'), findsNothing);
      expect(s.positionListening, isTrue);
      await _unmount(tester);
    },
  );

  testWidgets('mark shows approximate-location warning instead of hiding it', (
    tester,
  ) async {
    // Answer HapticFeedback calls so the mark flow can complete.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    final s = FakeSensors();
    await _pumpHome(
      tester,
      s,
      collect: ({required onProgress, bool forceWithBest = false}) async =>
          const PreciseMarkResult(
            latitude: 41.8781,
            longitude: -87.6298,
            accuracyMeters: 4,
            sampleCount: 5,
            altitudeMeters: null,
            forced: false,
            accuracyWarning:
                'Precise location declined. Mark will be approximate.',
          ),
    );
    s.emitPosition(fakePosition(accuracy: 3));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('MARK SPOT'));
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }

    expect(find.textContaining('Marked · ±13 ft · 5 samples'), findsOneWidget);
    // Mark re-checks permission but must not tear down the live stream.
    expect(s.positionListens, 1);
    expect(s.positionCancels, 0);
    expect(find.byKey(const Key('accuracyNote')), findsOneWidget);
    expect(find.text('REPLACE SPOT'), findsOneWidget);

    // Live fixes must not wipe the confirmation while it is held…
    s.emitPosition(fakePosition(accuracy: 3));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Marked · ±13 ft · 5 samples'), findsOneWidget);

    // …then the live GPS line returns; the warning must stay.
    await tester.pump(const Duration(seconds: 7));
    s.emitPosition(fakePosition(accuracy: 3));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Ready'), findsOneWidget);
    expect(
      find.text('Precise location declined. Mark will be approximate.'),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('permission denied: Mark goes to Settings, not the GPS dialog', (
    tester,
  ) async {
    final s = FakeSensors()
      ..permission = LocationPermission.deniedForever
      ..permissionAfterRequest = LocationPermission.deniedForever;
    await _pumpHome(tester, s);

    await tester.tap(find.text('MARK (WAIT / ANYWAY)'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(s.openAppSettingsCalls, 1);
    expect(find.text('GPS not ready'), findsNothing);
    await _unmount(tester);
  });

  testWidgets("away from the spot keeps the screen on; arriving shows YOU'RE HERE", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'spot.v1': jsonEncode({
        'lat': 41.8781,
        'lon': -87.6298,
        'acc': 4.0,
        'at': DateTime.now().toIso8601String(),
        'alt': null,
      }),
    });
    final s = FakeSensors();
    await _pumpHome(tester, s);
    await tester.pump();
    await tester.pump();

    s.emitPosition(fakePosition(lat: 41.8791)); // ~110 m north
    await tester.pump();
    await tester.pump();
    expect(find.text("YOU'RE HERE"), findsNothing);
    expect(s.keepAwake, isTrue);

    s.emitPosition(fakePosition()); // back at the spot
    await tester.pump();
    await tester.pump();
    expect(find.text("YOU'RE HERE"), findsOneWidget);
    expect(s.keepAwake, isFalse);

    s.emitPosition(fakePosition(lat: 41.8791));
    await tester.pump();
    await tester.pump();
    expect(s.keepAwake, isTrue);
    await _background(tester);
    expect(s.keepAwake, isFalse, reason: 'backgrounding releases the screen');
    await _unmount(tester);
  });

  testWidgets('compass heading is corrected to true north', (tester) async {
    final s = FakeSensors()..headingCorrectionDeg = 12;
    await _pumpHome(tester, s);

    s.emitPosition(fakePosition()); // first fix resolves the correction
    await tester.pump();
    await tester.pump();
    s.emitHeading(350);
    await tester.pump();

    expect(_compassHeading(tester), closeTo(2, 0.01));
    await _unmount(tester);
  });

  testWidgets('no compass: arrow follows direction of travel once walking', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'spot.v1': _storedSpot()});
    final s = FakeSensors()..hasCompass = false;
    await _pumpHome(tester, s);
    await tester.pump();
    await tester.pump();

    s.emitPosition(fakePosition(lat: 41.8791)); // standing still
    await tester.pump();
    await tester.pump();
    expect(find.byType(AnimatedRotation), findsNothing);
    expect(find.textContaining('no compass'), findsWidgets);

    s.emitPosition(fakePosition(lat: 41.8791, speed: 1.6, heading: 180));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AnimatedRotation), findsOneWidget);
    expect(find.textContaining('by direction of travel'), findsOneWidget);
    await _unmount(tester);
  });

  double turns(WidgetTester tester) =>
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns;

  testWidgets('driving: arrow follows GPS course, not the compass', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'spot.v1': _storedSpot()});
    final s = FakeSensors();
    await _pumpHome(tester, s);
    await tester.pump();
    await tester.pump();

    // Spot is due south (180). Phone compass says east; car heads south.
    s.emitPosition(fakePosition(lat: 41.8791, speed: 10, heading: 180));
    await tester.pump();
    s.emitHeading(90);
    await tester.pump();
    await tester.pump();
    expect(turns(tester), closeTo(0, 0.001));
    expect(find.textContaining('by direction of travel'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('slow: arrow follows the compass', (tester) async {
    SharedPreferences.setMockInitialValues({'spot.v1': _storedSpot()});
    final s = FakeSensors();
    await _pumpHome(tester, s);
    await tester.pump();
    await tester.pump();

    s.emitPosition(fakePosition(lat: 41.8791, speed: 1.5, heading: 180));
    await tester.pump();
    s.emitHeading(90);
    await tester.pump();
    await tester.pump();
    expect(turns(tester), closeTo(0.25, 0.001)); // spot 90 deg to the right
    expect(find.textContaining('by direction of travel'), findsNothing);
    await _unmount(tester);
  });
}
