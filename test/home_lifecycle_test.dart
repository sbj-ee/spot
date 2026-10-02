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

    // The next live fix rewrites the status line; the warning must stay.
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
}
