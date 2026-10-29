// In-app updater, following zwriter's flow:
//   GitHub "latest release" -> download SHA256SUMS + SHA256SUMS.minisig ->
//   verify the minisign signature with the embedded public key -> download
//   spot-<version>.apk -> check its SHA-256 against the signed list -> hand
//   the file to Android's package installer.
// Android shows its own install confirmation and also refuses an APK that
// isn't signed with the same certificate as the installed app.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';
import 'minisign.dart';

const String kReleasesApi =
    'https://api.github.com/repos/sbj-ee/spot/releases/latest';
const String kReleasesPage = 'https://github.com/sbj-ee/spot/releases';
const String kCheckAtStartupPref = 'checkUpdatesAtStartup';
const String kSkippedVersionPref = 'skippedUpdateVersion';

/// Fetches [url] and returns the body. Throws on any non-200 answer.
typedef Fetch = Future<List<int>> Function(Uri url);

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Release {
  Release({required this.tag, required this.htmlUrl, required this.assets});
  final String tag;
  final String htmlUrl;
  final Map<String, String> assets; // name -> browser_download_url

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  /// The .apk in this release, e.g. "spot-0.2.0+9.apk".
  String? get apkName {
    for (final n in assets.keys) {
      if (n.startsWith('spot-') && n.endsWith('.apk')) return n;
    }
    return null;
  }

  static Release parse(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final assets = <String, String>{};
    for (final a in (j['assets'] as List? ?? const [])) {
      final m = a as Map<String, dynamic>;
      final name = m['name'], url = m['browser_download_url'];
      if (name is String && url is String) assets[name] = url;
    }
    final tag = j['tag_name'];
    if (tag is! String || tag.isEmpty)
      throw UpdateException('Release has no tag.');
    final html = j['html_url'];
    return Release(
      tag: tag,
      htmlUrl: html is String ? html : kReleasesPage,
      assets: assets,
    );
  }
}

List<int> _parts(String v) {
  final core = v.split('+').first.split('-').first;
  return core.split('.').map((p) => int.tryParse(p) ?? 0).toList();
}

/// <0, 0, >0 like compareTo, on major.minor.patch (the +build suffix and any
/// leading "v" are ignored).
int compareVersions(String a, String b) {
  final x = _parts(a.replaceFirst(RegExp('^v'), ''));
  final y = _parts(b.replaceFirst(RegExp('^v'), ''));
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

bool isNewer(Release r, [String current = kAppVersion]) =>
    compareVersions(r.version, current) > 0;

/// Only HTTPS release-download URLs of this repo, with no path tricks.
bool trustedDownloadUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null ||
      u.scheme != 'https' ||
      u.host != 'github.com' ||
      u.hasQuery ||
      u.hasFragment) {
    return false;
  }
  if (u.userInfo.isNotEmpty || (u.hasPort && u.port != 443)) return false;
  final s = u.pathSegments;
  return s.length == 6 &&
      s[0] == 'sbj-ee' &&
      s[1] == 'spot' &&
      s[2] == 'releases' &&
      s[3] == 'download' &&
      s
          .skip(4)
          .every(
            (p) => p.isNotEmpty && p != '.' && p != '..' && !p.contains('/'),
          );
}

/// The SHA-256 (lower-case hex) listed for [name] in a SHA256SUMS file.
String? checksumFor(String sums, String name) {
  for (final raw in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+?)\s*$').firstMatch(raw);
    if (m != null && m.group(2) == name) return m.group(1)!.toLowerCase();
  }
  return null;
}

/// Downloads and verifies the release APK. Returns its bytes only when the
/// SHA256SUMS signature checks out and the APK's hash is listed in it.
Future<List<int>> downloadVerified(
  Release r,
  Fetch fetch, {
  String publicKey = kUpdateSigningPublicKey,
}) async {
  final apk = r.apkName;
  if (apk == null)
    throw UpdateException('This release has no Android package.');
  final sumsUrl = r.assets['SHA256SUMS'];
  final sigUrl = r.assets['SHA256SUMS.minisig'];
  if (sumsUrl == null || sigUrl == null) {
    throw UpdateException(
      "This release isn't signed, so it can't be installed from here.",
    );
  }
  final apkUrl = r.assets[apk]!;
  for (final u in [sumsUrl, sigUrl, apkUrl]) {
    if (!trustedDownloadUrl(u))
      throw UpdateException('Unexpected download address: $u');
  }
  final sums = await fetch(Uri.parse(sumsUrl));
  final sig = await fetch(Uri.parse(sigUrl));
  final why = minisignVerify(
    publicKey,
    sums,
    utf8.decode(sig, allowMalformed: true),
  );
  if (why != null) {
    throw UpdateException(
      "The release's signature is not valid ($why). Nothing was installed.",
    );
  }
  final want = checksumFor(utf8.decode(sums, allowMalformed: true), apk);
  if (want == null)
    throw UpdateException('$apk is not listed in the signed SHA256SUMS.');
  final bytes = await fetch(Uri.parse(apkUrl));
  final got = sha256.convert(bytes).toString();
  if (got != want) {
    throw UpdateException(
      "The download does not match the signed checksum. Nothing was installed.",
    );
  }
  return bytes;
}

/// Plain dart:io fetcher; follows GitHub's redirect to its download host.
Future<List<int>> httpFetch(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'Spot/$kAppVersion');
    if (url.host == 'api.github.com') {
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    }
    final res = await req.close().timeout(const Duration(minutes: 5));
    if (res.statusCode != 200)
      throw UpdateException('GitHub answered ${res.statusCode}.');
    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > 200 * 1024 * 1024)
        throw UpdateException('Download is too large.');
    }
    return out.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<Release> fetchLatest([Fetch fetch = httpFetch]) async =>
    Release.parse(utf8.decode(await fetch(Uri.parse(kReleasesApi))));

class UpdatePrefs {
  /// Off by default: Spot works offline, so it only talks to GitHub when
  /// asked to.
  static Future<bool> checkAtStartup() async =>
      (await SharedPreferences.getInstance()).getBool(kCheckAtStartupPref) ??
      false;
  static Future<void> setCheckAtStartup(bool on) async =>
      (await SharedPreferences.getInstance()).setBool(kCheckAtStartupPref, on);
  static Future<String?> skipped() async =>
      (await SharedPreferences.getInstance()).getString(kSkippedVersionPref);
  static Future<void> skip(String version) async =>
      (await SharedPreferences.getInstance()).setString(
        kSkippedVersionPref,
        version,
      );
}

/// Android side: MainActivity's "ee.sbj.spot/installer" channel.
class ApkInstaller {
  static const _ch = MethodChannel('ee.sbj.spot/installer');

  /// Writes [bytes] into the app cache and opens the system installer.
  /// Returns "started", or "needs_permission" when the user must first allow
  /// Spot to install apps (Android opens that settings page).
  static Future<String> install(String name, List<int> bytes) async {
    final dir = await _ch.invokeMethod<String>('cacheDir');
    if (dir == null) throw UpdateException('No cache directory.');
    final updates = Directory('$dir/updates');
    if (updates.existsSync()) updates.deleteSync(recursive: true);
    updates.createSync(recursive: true);
    final f = File(
      '${updates.path}/${name.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_')}',
    );
    await f.writeAsBytes(bytes, flush: true);
    return await _ch.invokeMethod<String>('installApk', {'path': f.path}) ??
        'failed';
  }
}
