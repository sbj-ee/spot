import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot/precise_mark.dart';

void main() {
  test('temporary full-accuracy purpose key exists in iOS Info.plist', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final dict = RegExp(
      r'<key>NSLocationTemporaryUsageDescriptionDictionary</key>\s*<dict>(.*?)</dict>',
      dotAll: true,
    ).firstMatch(plist);
    expect(
      dict,
      isNotNull,
      reason: 'Info.plist needs NSLocationTemporaryUsageDescriptionDictionary',
    );
    final keys = RegExp(
      r'<key>([^<]+)</key>\s*<string>[^<]+</string>',
    ).allMatches(dict!.group(1)!).map((m) => m.group(1)).toList();
    expect(keys, contains(kPreciseAccuracyPurposeKey));
  });

  test('no other purposeKey literal is used in lib/', () {
    final literal = RegExp(r'''purposeKey:\s*['"]''');
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      expect(
        literal.hasMatch(f.readAsStringSync()),
        isFalse,
        reason: '${f.path} should use kPreciseAccuracyPurposeKey',
      );
    }
  });
}
