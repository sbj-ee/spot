import 'package:flutter/material.dart';

import 'diag_platform.dart';
import 'diagnostics.dart';
import 'version.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.diagnostics});

  final DiagnosticsLog diagnostics;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Settings')),
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
            const ListTile(
              title: Text('Version'),
              subtitle: Text(kAppVersion),
            ),
          ],
        ),
      ),
    );
  }
}
