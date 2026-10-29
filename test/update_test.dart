import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:spot/update/blake2b.dart';
import 'package:spot/update/ed25519.dart';
import 'package:spot/update/minisign.dart';
import 'package:spot/update/updater.dart';

String _pub(String path) => File(path).readAsLinesSync()[1];
List<int> _hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];
String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const _base = 'https://github.com/sbj-ee/spot/releases/download/v9.9.9';

String _releaseJson({bool signed = true, String tag = 'v9.9.9'}) => jsonEncode({
  'tag_name': tag,
  'html_url': 'https://github.com/sbj-ee/spot/releases/tag/$tag',
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
});

/// Serves test/data/flow/NAME for release URLs; [override] replaces a file.
Fetch _fakeGitHub({
  Map<String, List<int>> override = const {},
  List<Uri>? log,
}) => (Uri u) async {
  log?.add(u);
  final name = u.pathSegments.last;
  if (override.containsKey(name)) return override[name]!;
  return File('test/data/flow/$name').readAsBytesSync();
};

void main() {
  group('BLAKE2b-512', () {
    test('RFC 7693 "abc" vector', () {
      expect(
        _toHex(blake2b512(utf8.encode('abc'))),
        'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1'
        '7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
      );
    });
    test('empty input and multi-block input', () {
      expect(_toHex(blake2b512([])).substring(0, 16), '786a02f742015903');
      // 128 bytes exactly (one full final block) and 129 bytes (two blocks).
      expect(blake2b512(List.filled(128, 0)).length, 64);
      expect(
        blake2b512(List.filled(129, 0)),
        isNot(blake2b512(List.filled(128, 0))),
      );
    });
  });

  group('Ed25519', () {
    // RFC 8032 section 7.1, TEST 2.
    final pk = _hex(
      '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    );
    final sig = _hex(
      '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
      '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
    );
    test(
      'RFC 8032 test 2 verifies',
      () => expect(ed25519Verify(pk, [0x72], sig), isTrue),
    );
    test('wrong message or flipped bit fails', () {
      expect(ed25519Verify(pk, [0x73], sig), isFalse);
      final bad = List<int>.of(sig)..[5] ^= 1;
      expect(ed25519Verify(pk, [0x72], bad), isFalse);
    });
  });

  group('minisign (real minisign 0.12 output)', () {
    final pub = _pub('test/data/minisign/test.pub');
    final sums = File('test/data/minisign/SHA256SUMS').readAsBytesSync();
    final sig = File(
      'test/data/minisign/SHA256SUMS.minisig',
    ).readAsStringSync();
    test(
      'prehashed ED signature verifies',
      () => expect(minisignVerify(pub, sums, sig), isNull),
    );
    test('legacy Ed signature verifies', () {
      expect(
        minisignVerify(
          pub,
          File('test/data/minisign/SHA256SUMS.legacy').readAsBytesSync(),
          File(
            'test/data/minisign/SHA256SUMS.legacy.minisig',
          ).readAsStringSync(),
        ),
        isNull,
      );
    });
    test('tampered data fails', () {
      final t = List<int>.of(sums)..[0] ^= 1;
      expect(minisignVerify(pub, t, sig), isNotNull);
    });
    test('edited trusted comment fails', () {
      expect(
        minisignVerify(
          pub,
          sums,
          sig.replaceFirst('timestamp:0', 'timestamp:1'),
        ),
        isNotNull,
      );
    });
    test('other key (the release key) is rejected', () {
      expect(
        minisignVerify(kUpdateSigningPublicKey, sums, sig),
        'signed with a different key',
      );
    });
    test(
      'garbage is rejected',
      () => expect(minisignVerify(pub, sums, 'nope'), isNotNull),
    );
  });

  test('embedded key is the shared release key DBC46B23C3AF0EF3', () {
    final raw = base64.decode(kUpdateSigningPublicKey);
    expect(raw.length, 42);
    expect(
      _toHex(raw.sublist(2, 10).reversed.toList()).toUpperCase(),
      'DBC46B23C3AF0EF3',
    );
  });

  group('release parsing and policy', () {
    test('parses assets and picks the apk', () {
      final r = Release.parse(_releaseJson());
      expect(r.version, '9.9.9');
      expect(r.apkName, 'spot-9.9.9+99.apk');
      expect(isNewer(r, '0.2.0+9'), isTrue);
      expect(
        isNewer(Release.parse(_releaseJson(tag: 'v0.2.0')), '0.2.0+9'),
        isFalse,
      );
    });
    test('version compare ignores build suffix', () {
      expect(compareVersions('0.2.0', '0.1.5+8'), greaterThan(0));
      expect(compareVersions('v0.1.5', '0.1.5+8'), 0);
      expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    });
    test('checksum lookup', () {
      final s = '${'a' * 64}  spot-1.apk\n${'B' * 64} *spot-2.apk\r\n';
      expect(checksumFor(s, 'spot-2.apk'), 'b' * 64);
      expect(checksumFor(s, 'spot-3.apk'), isNull);
    });
    test('only this repo\'s https release downloads are trusted', () {
      expect(trustedDownloadUrl('$_base/SHA256SUMS'), isTrue);
      expect(trustedDownloadUrl('$_base/spot-9.9.9%2B99.apk'), isTrue);
      expect(
        trustedDownloadUrl(
          'http://github.com/sbj-ee/spot/releases/download/v1/x',
        ),
        isFalse,
      );
      expect(
        trustedDownloadUrl(
          'https://github.com/evil/spot/releases/download/v1/x',
        ),
        isFalse,
      );
      expect(
        trustedDownloadUrl(
          'https://github.com.evil.io/sbj-ee/spot/releases/download/v1/x',
        ),
        isFalse,
      );
      expect(
        trustedDownloadUrl(
          'https://github.com/sbj-ee/spot/releases/download/v1/x?y=1',
        ),
        isFalse,
      );
      expect(
        trustedDownloadUrl(
          'https://github.com/sbj-ee/spot/releases/download/v1/a/b',
        ),
        isFalse,
      );
    });
  });

  group('download + verify flow', () {
    final key = _pub('test/data/flow/flow.pub');
    final apk = File('test/data/flow/spot-9.9.9+99.apk').readAsBytesSync();

    test('good release returns the verified apk', () async {
      final log = <Uri>[];
      final got = await downloadVerified(
        Release.parse(_releaseJson()),
        _fakeGitHub(log: log),
        publicKey: key,
      );
      expect(sha256.convert(got), sha256.convert(apk));
      // Signature is checked before the apk is fetched.
      expect(log.map((u) => u.pathSegments.last), [
        'SHA256SUMS',
        'SHA256SUMS.minisig',
        'spot-9.9.9+99.apk',
      ]);
    });
    test('tampered apk is refused', () async {
      expect(
        downloadVerified(
          Release.parse(_releaseJson()),
          _fakeGitHub(override: {'spot-9.9.9+99.apk': utf8.encode('evil')}),
          publicKey: key,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('does not match'),
          ),
        ),
      );
    });
    test('tampered SHA256SUMS is refused before the apk is fetched', () async {
      final log = <Uri>[];
      final sums = File(
        'test/data/flow/SHA256SUMS',
      ).readAsStringSync().replaceFirst('0', '1');
      await expectLater(
        downloadVerified(
          Release.parse(_releaseJson()),
          _fakeGitHub(override: {'SHA256SUMS': utf8.encode(sums)}, log: log),
          publicKey: key,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('signature'),
          ),
        ),
      );
      expect(log.any((u) => u.path.endsWith('.apk')), isFalse);
    });
    test('release signed by another key is refused (embedded key)', () {
      expect(
        downloadVerified(Release.parse(_releaseJson()), _fakeGitHub()),
        throwsA(isA<UpdateException>()),
      );
    });
    test('unsigned release is refused', () {
      expect(
        downloadVerified(
          Release.parse(_releaseJson(signed: false)),
          _fakeGitHub(),
          publicKey: key,
        ),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains("isn't signed"),
          ),
        ),
      );
    });
    test('off-repo asset URL is refused', () {
      final j = _releaseJson().replaceAll('sbj-ee/spot', 'evil/spot');
      expect(
        downloadVerified(Release.parse(j), _fakeGitHub(), publicKey: key),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  test('manifest declares installer permission and FileProvider', () {
    final m = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(m, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    expect(m, contains('android.permission.INTERNET'));
    expect(m, contains(r'${applicationId}.updates'));
    expect(
      File('android/app/src/main/res/xml/update_paths.xml').readAsStringSync(),
      contains('path="updates/"'),
    );
  });

  test('release workflow signs SHA256SUMS', () {
    final w = File('.github/workflows/release.yml').readAsStringSync();
    expect(w, contains('secrets.MINISIGN_SECRET_KEY'));
    expect(w, contains('SHA256SUMS.minisig'));
  });
}
