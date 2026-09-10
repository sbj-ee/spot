import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import 'geo_math.dart';
import 'precise_mark.dart';
import 'spot_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = SpotStore();

  SavedSpot? _spot;
  Position? _here;
  double? _headingDeg; // device heading (0 = north)
  String? _status;
  bool _busy = false;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _ageTick;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    _ageTick?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final spot = await _store.load();
    if (!mounted) return;
    setState(() => _spot = spot);
    await _ensurePermissionsAndListen();
    _ageTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<bool> _ensurePermissionsAndListen() async {
    setState(() => _status = 'Checking location…');

    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      setState(() => _status = 'Turn on Location / GPS');
      return false;
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission required');
      await Geolocator.openAppSettings();
      return false;
    }

    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: highAccuracySettings(),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _here = pos;
        if (_busy) return; // mark flow owns status while sampling
        if (pos.accuracy <= kReadyAccuracyMeters) {
          _status = 'Ready · ${formatAccuracyFeet(pos.accuracy)}';
        } else {
          _status = 'Waiting for better fix · ${formatAccuracyFeet(pos.accuracy)}';
        }
      });
    }, onError: (e) {
      if (!mounted) return;
      setState(() => _status = 'GPS error: $e');
    });

    await _compassSub?.cancel();
    final compass = FlutterCompass.events;
    if (compass != null) {
      _compassSub = compass.listen((event) {
        if (!mounted) return;
        final h = event.heading;
        if (h == null) return;
        setState(() => _headingDeg = normalizeDegrees(h));
      });
    } else {
      setState(() => _status = (_status ?? '') + ' (no compass)');
    }

    // Seed from last known only (do not treat as mark-quality).
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        setState(() {
          _here = last;
          _status = 'Waiting for better fix · ${formatAccuracyFeet(last.accuracy)}';
        });
      }
    } catch (_) {}

    if (mounted && _status == 'Checking location…') {
      setState(() => _status = 'Waiting for GPS…');
    }
    return true;
  }

  Future<void> _markSpot({bool forceAnyway = false}) async {
    if (_busy) return;

    final here = _here;
    final ready = here != null && here.accuracy <= kReadyAccuracyMeters;
    if (!forceAnyway && !ready) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('GPS not ready', style: TextStyle(color: Colors.white)),
          content: Text(
            here == null
                ? 'No fix yet. Wait outdoors with a clear sky, or mark with a weaker fix.'
                : 'Current accuracy ${formatAccuracyFeet(here.accuracy)} (want ≤ ±16 ft). '
                    'Wait for Ready, or mark anyway.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Wait')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'anyway'),
              child: const Text('Mark anyway', style: TextStyle(color: Color(0xFFFFCC00))),
            ),
          ],
        ),
      );
      if (choice != 'anyway') return;
      forceAnyway = true;
    }

    setState(() {
      _busy = true;
      _status = 'Warming up GPS…';
    });
    try {
      final ok = await _ensurePermissionsAndListen();
      if (!ok) return;

      // Prompt high-accuracy mode if services look coarse / off-path.
      try {
        final serviceOn = await Geolocator.isLocationServiceEnabled();
        if (!serviceOn) {
          await Geolocator.openLocationSettings();
        }
      } catch (_) {}

      final result = await collectPreciseMark(
        forceWithBest: forceAnyway,
        onProgress: (msg, latest) {
          if (!mounted) return;
          setState(() {
            _status = msg;
            if (latest != null) _here = latest;
          });
        },
      );

      if (result == null) {
        if (!mounted) return;
        setState(() => _status = 'Mark failed: no usable GPS samples');
        return;
      }

      final spot = SavedSpot(
        latitude: result.latitude,
        longitude: result.longitude,
        accuracyMeters: result.accuracyMeters,
        markedAt: DateTime.now(),
        altitudeMeters: result.altitudeMeters,
      );
      await _store.save(spot);
      await HapticFeedback.heavyImpact();
      if (!mounted) return;
      setState(() {
        _spot = spot;
        _status = result.forced
            ? 'Marked (best available · ${formatAccuracyFeet(result.accuracyMeters)})'
            : 'Marked · ${formatAccuracyFeet(result.accuracyMeters)} · ${result.sampleCount} samples';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Mark failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearSpot() async {
    await _store.clear();
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _spot = null);
  }

  Future<void> _confirmReplaceOrClear({required bool clearOnly}) async {
    final action = clearOnly ? 'Clear' : 'Replace';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('$action spot?', style: const TextStyle(color: Colors.white)),
        content: Text(
          clearOnly
              ? 'Remove the saved spot from this phone.'
              : 'Overwrite the saved spot with your current GPS fix.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action, style: const TextStyle(color: Color(0xFFFFCC00))),
          ),
        ],
      ),
    );
    if (go != true) return;
    if (clearOnly) {
      await _clearSpot();
    } else {
      await _markSpot();
    }
  }

  @override
  Widget build(BuildContext context) {
    final here = _here;
    final spot = _spot;
    final heading = _headingDeg;

    double? distanceM;
    double? bearingDeg;
    double? relativeDeg;
    if (here != null && spot != null) {
      distanceM = Geolocator.distanceBetween(
        here.latitude,
        here.longitude,
        spot.latitude,
        spot.longitude,
      );
      bearingDeg = Geolocator.bearingBetween(
        here.latitude,
        here.longitude,
        spot.latitude,
        spot.longitude,
      );
      if (heading != null) {
        relativeDeg = shortestAngleDelta(heading, bearingDeg);
      }
    }

    final gpsReady = here != null && here.accuracy <= kReadyAccuracyMeters;
    final gpsWeak = here != null && here.accuracy > 30; // ~100 ft
    final fixAge = formatFixAge(here?.timestamp);
    final accLabel = formatAccuracyFeet(here?.accuracy);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'SPOT',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFFFCC00),
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _status ??
                    (here == null
                        ? 'Waiting for GPS…'
                        : '${gpsReady ? 'Ready' : 'Waiting for better fix'} · $accLabel · $fixAge${gpsWeak ? ' · WEAK' : ''}'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: gpsWeak
                      ? const Color(0xFFFF6666)
                      : (gpsReady ? const Color(0xFF66FF99) : Colors.white70),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: spot == null
                    ? const Center(
                        child: Text(
                          'No spot marked',
                          style: TextStyle(color: Colors.white38, fontSize: 22),
                        ),
                      )
                    : Column(
                        children: [
                          Expanded(
                            child: Center(
                              child: _Arrow(
                                relativeDeg: relativeDeg,
                                headingMissing: heading == null,
                              ),
                            ),
                          ),
                          Text(
                            distanceM == null ? '—' : formatDistance(distanceM),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 64,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            bearingDeg == null
                                ? ''
                                : 'Bearing ${bearingDeg.round()}° ${bearingCardinal(bearingDeg)}'
                                    '${heading == null ? ' · no compass' : ''}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54, fontSize: 16),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Marked ${formatFixAge(spot.markedAt)} · ${formatAccuracyFeet(spot.accuracyMeters)}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white38, fontSize: 14),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              if (spot == null)
                _BigButton(
                  label: _busy
                      ? 'MARKING…'
                      : (gpsReady ? 'MARK SPOT' : 'MARK (WAIT / ANYWAY)'),
                  color: const Color(0xFFFFCC00),
                  textColor: Colors.black,
                  onPressed: _busy ? null : () => _markSpot(),
                )
              else ...[
                _BigButton(
                  label: _busy ? 'REPLACING…' : 'REPLACE SPOT',
                  color: const Color(0xFFFFCC00),
                  textColor: Colors.black,
                  onPressed: _busy ? null : () => _confirmReplaceOrClear(clearOnly: false),
                ),
                const SizedBox(height: 12),
                _BigButton(
                  label: 'CLEAR',
                  color: const Color(0xFF333333),
                  textColor: Colors.white,
                  onPressed: () => _confirmReplaceOrClear(clearOnly: true),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Local only · offline after mark · no map',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white24, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: color.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.relativeDeg, required this.headingMissing});

  final double? relativeDeg;
  final bool headingMissing;

  @override
  Widget build(BuildContext context) {
    if (headingMissing || relativeDeg == null) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.explore_off, color: Colors.white24, size: 96),
          SizedBox(height: 8),
          Text('Point phone forward\n(compass calibrating)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 16)),
        ],
      );
    }
    final rad = degToRad(relativeDeg!);
    return Transform.rotate(
      angle: rad,
      child: CustomPaint(
        size: const Size(220, 220),
        painter: _ArrowPainter(),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFCC00)
      ..style = PaintingStyle.fill;
    final path = Path();
    final w = size.width;
    final h = size.height;
    // Point up (toward bearing when relativeDeg==0)
    path.moveTo(w * 0.5, h * 0.05);
    path.lineTo(w * 0.82, h * 0.78);
    path.lineTo(w * 0.5, h * 0.62);
    path.lineTo(w * 0.18, h * 0.78);
    path.close();
    canvas.drawPath(path, paint);

    final hub = Paint()..color = Colors.black;
    canvas.drawCircle(Offset(w * 0.5, h * 0.55), 10, hub);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
