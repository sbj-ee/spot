import 'package:flutter/material.dart';

import 'diag_platform.dart';
import 'diagnostics.dart';
import 'update/update_ui.dart';
import 'update/updater.dart';
import 'version.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.diagnostics,
    this.showUpdater,
  });

  final DiagnosticsLog diagnostics;

  /// Defaults to [updaterSupported] (Android). Tests force it on.
  final bool? showUpdater;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _checkAtStartup = false;

  bool get _updater => widget.showUpdater ?? updaterSupported;

  @override
  void initState() {
    super.initState();
    if (_updater) {
      UpdatePrefs.checkAtStartup().then((v) {
        if (mounted) setState(() => _checkAtStartup = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.diagnostics;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Settings'),
      ),
      body: ListenableBuilder(
        listenable: diagnostics,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              key: const Key('diagToggle'),
              title: const Text('Diagnostics log'),
              subtitle: const Text(
                'Records every GPS fix and Mark decision on this phone so you can '
                'export it. Keeps the screen on while enabled. Off by default.',
              ),
              value: diagnostics.enabled,
              onChanged: (on) async {
                await diagnostics.setEnabled(on);
                await DiagPlatform.keepScreenOn(on);
              },
            ),
            if (_updater) ...[
              ListTile(
                key: const Key('checkForUpdates'),
                leading: const Icon(Icons.system_update),
                title: const Text('Check for updates…'),
                subtitle: const Text(
                  'Looks for a newer signed release on GitHub.',
                ),
                onTap: () => checkForUpdates(context, manual: true),
              ),
              SwitchListTile(
                key: const Key('checkAtStartupToggle'),
                title: const Text('Check for updates at startup'),
                subtitle: const Text(
                  'Asks GitHub once when Spot opens. Nothing else leaves the phone. Off by default.',
                ),
                value: _checkAtStartup,
                onChanged: (on) async {
                  await UpdatePrefs.setCheckAtStartup(on);
                  setState(() => _checkAtStartup = on);
                },
              ),
            ],
            const ListTile(title: Text('Version'), subtitle: Text(kAppVersion)),
          ],
        ),
      ),
    );
  }
}
