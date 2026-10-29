import 'dart:io';

import 'package:flutter/material.dart';

import '../version.dart';
import 'updater.dart';

/// Whether this build can update itself (Android only; iOS updates come
/// through TestFlight / the App Store).
bool get updaterSupported => Platform.isAndroid;

enum UpdateChoice { install, skip, later }

/// The "Spot X is available" dialog.
class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    super.key,
    required this.release,
    this.current = kAppVersion,
  });
  final Release release;
  final String current;

  @override
  Widget build(BuildContext context) {
    final signed = release.assets.containsKey('SHA256SUMS.minisig');
    return AlertDialog(
      title: const Text('Update available'),
      content: Text(
        'Spot ${release.version} is available. You have $current.\n\n'
        '${signed ? 'Install downloads the APK, checks its signed SHA-256, then hands it to Android\'s installer.' : 'This release is not signed, so it can\'t be installed from here.'}',
      ),
      actions: [
        TextButton(
          key: const Key('updateSkip'),
          onPressed: () => Navigator.pop(context, UpdateChoice.skip),
          child: const Text('Skip this version'),
        ),
        TextButton(
          key: const Key('updateLater'),
          onPressed: () => Navigator.pop(context, UpdateChoice.later),
          child: const Text('Later'),
        ),
        FilledButton(
          key: const Key('updateInstall'),
          onPressed: signed
              ? () => Navigator.pop(context, UpdateChoice.install)
              : null,
          child: const Text('Install'),
        ),
      ],
    );
  }
}

Future<void> _info(BuildContext context, String title, String body) =>
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );

/// Checks GitHub and walks the user through installing. [manual] is true
/// for the Settings button (it reports "up to date" and errors); the startup
/// check stays quiet unless there is something new.
Future<void> checkForUpdates(
  BuildContext context, {
  required bool manual,
  Fetch fetch = httpFetch,
  Future<String> Function(String name, List<int> bytes) install =
      ApkInstaller.install,
}) async {
  final Release r;
  try {
    r = await fetchLatest(fetch);
  } catch (e) {
    if (manual && context.mounted) {
      await _info(context, 'Update check failed', "Couldn't reach GitHub: $e");
    }
    return;
  }
  if (!context.mounted) return;
  if (!isNewer(r)) {
    if (manual)
      await _info(
        context,
        'No updates',
        "You're on the latest version ($kAppVersion).",
      );
    return;
  }
  if (!manual && await UpdatePrefs.skipped() == r.version) return;
  if (!context.mounted) return;
  final choice = await showDialog<UpdateChoice>(
    context: context,
    builder: (_) => UpdateAvailableDialog(release: r),
  );
  if (choice == UpdateChoice.skip) await UpdatePrefs.skip(r.version);
  if (choice != UpdateChoice.install || !context.mounted) return;

  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    const SnackBar(content: Text('Downloading and verifying update…')),
  );
  try {
    final bytes = await downloadVerified(r, fetch);
    final res = await install(r.apkName!, bytes);
    if (!context.mounted) return;
    if (res == 'needs_permission') {
      await _info(
        context,
        'Allow installs',
        'Android needs your OK for Spot to install updates. Turn on "Allow from this source", come back, and tap Check for updates again.',
      );
    }
  } catch (e) {
    if (context.mounted) await _info(context, 'Update not installed', '$e');
  }
}
