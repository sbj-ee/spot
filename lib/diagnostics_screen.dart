import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';

import 'diagnostics.dart';
import 'geo_math.dart';
import 'version.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key, required this.log});

  final DiagnosticsLog log;

  static String _dur(Duration? d) =>
      d == null ? '—' : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';

  Future<void> _export(BuildContext context, {required bool json}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final name = 'spot-diag-$stamp.${json ? 'json' : 'csv'}';
      final body = json
          ? log.toJsonString(app: {'version': kAppVersion})
          : log.toCsv();
      // share_plus writes in-memory files to its own cache and shares them
      // through its FileProvider, so no storage permission is needed.
      final bytes = Uint8List.fromList(utf8.encode(body));
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(bytes,
                name: name, mimeType: json ? 'application/json' : 'text/plain'),
          ],
          fileNameOverrides: [name],
          subject: 'Spot diagnostics $name',
          text: 'Spot $kAppVersion diagnostics',
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _ab(String phase, String reason) {
    final p = log.lastFix;
    log.setAbPhase(
      phase,
      reason: reason,
      lat: p?.latitude,
      lon: p?.longitude,
      accuracyM: p?.accuracy,
      distToSpotM: log.distanceToSpot(p),
    );
  }

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Colors.white54, fontSize: 14);
    const value = TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(k, style: label)),
          Flexible(child: Text(v, style: value, textAlign: TextAlign.right)),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Diagnostics')),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final p = log.lastFix;
          final dev = log.deviceInfo;
          final dist = log.distanceToSpot(p);
          final hasSpot = log.spotLat != null;
          int? used;
          int? visible;
          if (p is AndroidPosition) {
            used = p.satellitesUsedInFix > 0 ? p.satellitesUsedInFix.round() : null;
            visible = p.satelliteCount > 0 ? p.satelliteCount.round() : null;
          }
          final ab = log.abSummary();
          final recent = log.events.reversed.take(40).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!log.enabled)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Diagnostics is off. Turn it on in Settings.',
                      style: TextStyle(color: Color(0xFFFFAA33))),
                ),
              row('Device', '${dev['model'] ?? '?'} · Android ${dev['release'] ?? '?'} (SDK ${dev['sdk_int'] ?? '?'})'),
              row('Provider', log.provider ?? '?'),
              row('GNSS chip', '${dev['gnss_hardware_model'] ?? '—'}'),
              const Divider(color: Colors.white24),
              row('Live accuracy', formatAccuracyFeet(p?.accuracy)),
              row('Satellites used / visible', '${used ?? '—'} / ${visible ?? '—'}'),
              row('Speed', p == null ? '—' : '${p.speed.toStringAsFixed(1)} m/s'),
              row('Bearing', p == null ? '—' : '${p.heading.round()}°'),
              row('Fix age', formatFixAge(p?.timestamp)),
              row('Best this session', formatAccuracyFeet(log.bestAccuracyM)),
              const Divider(color: Colors.white24),
              row('Time to first fix', _dur(log.timeToFirstFix)),
              for (final m in kMilestoneFeet) row('Time to ±$m ft', _dur(log.milestones[m])),
              const Divider(color: Colors.white24),
              const Text('A/B walk test', style: TextStyle(color: Color(0xFFFFCC00), fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                hasSpot
                    ? 'Phase: ${log.abPhase} · distance to saved spot: ${dist == null ? '—' : formatDistance(dist)}'
                    : 'Mark a spot first (that is point A).',
                style: label,
              ),
              if (ab['back_at_a_fixes'] != 0)
                Text(
                  'Back-at-A error: mean ${formatDistance(ab['error_mean_m'] as double)}, '
                  'max ${formatDistance(ab['error_max_m'] as double)} '
                  '(${ab['back_at_a_fixes']} fixes)',
                  style: value,
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: hasSpot && log.enabled ? () => _ab('at_a', 'standing on A') : null,
                    child: const Text('1 · On A'),
                  ),
                  FilledButton(
                    onPressed: hasSpot && log.enabled ? () => _ab('walking', 'walking to B') : null,
                    child: const Text('2 · Walking'),
                  ),
                  FilledButton(
                    onPressed: hasSpot && log.enabled ? () => _ab('at_b', 'standing on B') : null,
                    child: const Text('3 · At B'),
                  ),
                  FilledButton(
                    onPressed: hasSpot && log.enabled ? () => _ab('back_at_a', 'back on A') : null,
                    child: const Text('4 · Back on A'),
                  ),
                  OutlinedButton(
                    onPressed: log.abActive ? () => _ab('off', 'A/B finished') : null,
                    child: const Text('Finish'),
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => _export(context, json: false),
                    icon: const Icon(Icons.share),
                    label: const Text('Export CSV'),
                  ),
                  FilledButton.icon(
                    onPressed: () => _export(context, json: true),
                    icon: const Icon(Icons.share),
                    label: const Text('Export JSON'),
                  ),
                  OutlinedButton(
                    onPressed: log.clear,
                    child: const Text('Clear log'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('${log.events.length} events', style: label),
              for (final e in recent)
                Text(
                  '${e.at.toIso8601String().substring(11, 19)} ${e.kind.name} '
                  '${e.event ?? ''} ${e.accuracyM == null ? '' : formatAccuracyFeet(e.accuracyM)} '
                  '${e.reason ?? ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                ),
            ],
          );
        },
      ),
    );
  }
}
