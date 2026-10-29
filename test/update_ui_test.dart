// Widget tests for the updater UI. With SPOT_SCREENSHOT_DIR set (and
// FLUTTER_ROOT pointing at the SDK for its Roboto/MaterialIcons fonts) they
// also save PNG screenshots, e.g.
//   SPOT_SCREENSHOT_DIR=docs/screenshots flutter test test/update_ui_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spot/diagnostics.dart';
import 'package:spot/settings_screen.dart';
import 'package:spot/update/update_ui.dart';
import 'package:spot/update/updater.dart';

final _shotDir = Platform.environment['SPOT_SCREENSHOT_DIR'];
const _base = 'https://github.com/sbj-ee/spot/releases/download/v9.9.9';

Release _release({bool signed = true}) => Release.parse(
  jsonEncode({
    'tag_name': 'v9.9.9',
    'html_url': 'https://github.com/sbj-ee/spot/releases/tag/v9.9.9',
    'assets': [
      {
        'name': 'spot-9.9.9+99.apk',
        'browser_download_url': '$_base/spot-9.9.9%2B99.apk',
      },
      {'name': 'SHA256SUMS', 'browser_download_url': '$_base/SHA256SUMS'},
      if (signed)
        {
          'name': 'SHA256SUMS.minisig',
          'browser_download_url': '$_base/SHA256SUMS.minisig',
        },
    ],
  }),
);

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto')
    ..addFont(
      File(
        '$dir/Roboto-Regular.ttf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      File(
        '$dir/MaterialIcons-Regular.otf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  await roboto.load();
  await icons.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shotDir == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('shot')),
  );
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory(_shotDir!).createSync(recursive: true);
    File('$_shotDir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _app(Widget home) => RepaintBoundary(
  key: const Key('shot'),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: _shotDir == null ? null : 'Roboto',
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFFFCC00),
        surface: Colors.black,
      ),
      useMaterial3: true,
    ),
    home: home,
  ),
);

void main() {
  setUpAll(() async {
    if (_shotDir != null) await _loadFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'Settings shows Check for updates and an off-by-default startup toggle',
    (tester) async {
      await phone(tester);
      await tester.pumpWidget(
        _app(SettingsScreen(diagnostics: DiagnosticsLog(), showUpdater: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Check for updates…'), findsOneWidget);
      final toggle = find.byKey(const Key('checkAtStartupToggle'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await _shot(tester, 'settings');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(await UpdatePrefs.checkAtStartup(), isTrue);
    },
  );

  testWidgets('Settings hides the updater where unsupported', (tester) async {
    await tester.pumpWidget(
      _app(SettingsScreen(diagnostics: DiagnosticsLog(), showUpdater: false)),
    );
    expect(find.text('Check for updates…'), findsNothing);
  });

  testWidgets('Update dialog offers Install / Skip / Later', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: UpdateAvailableDialog(release: _release(), current: '0.2.0+9'),
        ),
      ),
    );
    expect(
      find.textContaining('Spot 9.9.9 is available. You have 0.2.0+9.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('updateInstall')))
          .onPressed,
      isNotNull,
    );
    await _shot(tester, 'update-dialog');
  });

  testWidgets('Unsigned release cannot be installed', (tester) async {
    await phone(tester);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: UpdateAvailableDialog(
            release: _release(signed: false),
            current: '0.2.0+9',
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('updateInstall')))
          .onPressed,
      isNull,
    );
    await _shot(tester, 'update-dialog-unsigned');
  });

  testWidgets(
    'Install with a bad signature reports it and never calls the installer',
    (tester) async {
      await phone(tester);
      var installed = false;
      final flow = Directory('test/data/flow');
      Future<List<int>> fetch(Uri u) async {
        if (u.host == 'api.github.com')
          return utf8.encode(
            jsonEncode({
              'tag_name': 'v9.9.9',
              'assets': [
                for (final n in [
                  'spot-9.9.9+99.apk',
                  'SHA256SUMS',
                  'SHA256SUMS.minisig',
                ])
                  {
                    'name': n,
                    'browser_download_url': '$_base/${Uri.encodeComponent(n)}',
                  },
              ],
            }),
          );
        return File('${flow.path}/${u.pathSegments.last}').readAsBytesSync();
      }

      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => checkForUpdates(
                  c,
                  manual: true,
                  fetch: fetch,
                  install: (n, b) async {
                    installed = true;
                    return 'started';
                  },
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('updateInstall')));
      // The fixtures are signed by the test key, not the embedded release key.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Update not installed'), findsOneWidget);
      expect(find.textContaining("signature is not valid"), findsOneWidget);
      expect(installed, isFalse);
      await _shot(tester, 'update-bad-signature');
    },
  );
}
