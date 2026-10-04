import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'diag_platform.dart';
import 'diagnostics.dart';
import 'diagnostics_screen.dart';
import 'geo_math.dart';
import 'precise_mark.dart';
import 'sensors.dart';
import 'settings_screen.dart';
import 'spot_store.dart';

typedef PreciseMarkCollector = Future<PreciseMarkResult?> Function({
  required void Function(String status, Position? latest) onProgress,
  bool forceWithBest,
});

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.sensors = const DeviceSensors(),
    this.store,
    this.collectMark,
    this.diagnostics,
  });

  final SpotSensors sensors;
  final SpotStore? store;

  /// Override for tests; defaults to [collectPreciseMark].
  final PreciseMarkCollector? collectMark;

  /// Diagnostics log; defaults to [DiagnosticsLog.instance].
  final DiagnosticsLog? diagnostics;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final SpotStore _store = widget.store ?? SpotStore();

  SavedSpot? _spot;
  Position? _here;
  double? _headingDeg; // device heading (0 = north)
  String? _status;

  /// Sticky warning from the last mark (approximate location / failed
  /// precise-accuracy check). Live GPS updates rewrite [_status], so this is
  /// shown on its own line until the next mark.
  String? _accuracyNote;
  bool _busy = false;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<double?>? _compassSub;
  Timer? _ageTick;

  /// False while the app is hidden/paused; sensors are stopped then.
  bool _foreground = true;

  /// Bumped on every start/stop so a slow async start that finishes after
  /// the app went to the background doesn't attach listeners.
  int _sensorGeneration = 0;

  SpotSensors get _sensors => widget.sensors;
  late final DiagnosticsLog _diag = widget.diagnostics ?? DiagnosticsLog.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _diag.addListener(_onDiagChanged);
    _bootstrap();
  }

  bool _diagWasEnabled = false;
  void _onDiagChanged() {
    if (!mounted || _diag.enabled == _diagWasEnabled) return;
    setState(() => _diagWasEnabled = _diag.enabled);
  }

  Future<void> _initDiagnostics() async {
    try {
      await _diag.loadEnabled();
      final info = await DiagPlatform.deviceInfo();
      _diag.deviceInfo = info;
      _diag.provider = DiagPlatform.effectiveProvider(
        forceLocationManager: kForceLocationManager,
        info: info,
      );
      if (_diag.enabled) {
        await DiagPlatform.keepScreenOn(true);
        _diag.note('app_start', 'diagnostics on · provider ${_diag.provider}');
      }
    } catch (e) {
      debugPrint('Spot: diagnostics init failed: $e');
    }
  }

  @override
  void dispose() {
    _diag.removeListener(_onDiagChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopSensors();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        _stopSensors();
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        // Re-check service + permission (user may be back from Settings),
        // without prompting or bouncing to Settings again.
        _ensurePermissionsAndListen(interactive: false);
      case AppLifecycleState.inactive:
        // Transient (permission sheets, app switcher): keep sensors running.
        break;
    }
  }

  void _stopSensors() {
    _sensorGeneration++;
    _posSub?.cancel();
    _posSub = null;
    _compassSub?.cancel();
    _compassSub = null;
    _ageTick?.cancel();
    _ageTick = null;
  }

  /// True while the background sensors are attached (exposed for tests).
  @visibleForTesting
  bool get sensorsActive => _posSub != null || _ageTick != null;

  Future<void> _bootstrap() async {
    final spot = await _store.load();
    if (!mounted) return;
    setState(() => _spot = spot);
    _diag.setSpot(spot?.latitude, spot?.longitude);
    // Not awaited: diagnostics must never delay GPS start.
    unawaited(_initDiagnostics());
    await _ensurePermissionsAndListen(interactive: true);
  }

  /// Checks location service + permission and starts the position stream,
  /// compass and age timer if they aren't already running.
  ///
  /// [interactive] may show the OS permission prompt. [openSettingsIfBlocked]
  /// (only on an explicit user tap) opens app Settings when permission is
  /// denied, so resume never loops the user back into Settings.
  Future<bool> _ensurePermissionsAndListen({
    required bool interactive,
    bool openSettingsIfBlocked = false,
  }) async {
    final gen = _sensorGeneration;
    bool stale() => !mounted || !_foreground || gen != _sensorGeneration;

    if (!_busy) setState(() => _status = 'Checking location…');

    final serviceOn = await _sensors.isLocationServiceEnabled();
    if (stale()) return false;
    if (!serviceOn) {
      setState(() => _status = 'Turn on Location / GPS');
      return false;
    }

    var perm = await _sensors.checkPermission();
    if (interactive && perm == LocationPermission.denied) {
      perm = await _sensors.requestPermission();
    }
    if (stale()) return false;
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever ||
        perm == LocationPermission.unableToDetermine) {
      setState(() => _status = 'Location permission required · tap Mark to open Settings');
      if (openSettingsIfBlocked) await _sensors.openAppSettings();
      return false;
    }

    // Already streaming (e.g. Mark while the screen is live): keep it.
    // Re-subscribing churns the platform GNSS/NMEA listeners for nothing.
    if (_posSub != null) return true;

    _diag.startSession('gps stream start');
    _posSub = _sensors.positionStream().listen((pos) {
      if (!mounted) return;
      _diag.recordFix(pos);
      setState(() {
        _here = pos;
        if (_busy) return; // mark flow owns status while sampling
        _status = liveFixStatus(pos.accuracy);
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => _status = 'GPS error: $e');
    });

    final compass = _sensors.headings();
    if (compass != null) {
      _compassSub = compass.listen((h) {
        if (!mounted || h == null) return;
        setState(() => _headingDeg = normalizeDegrees(h));
      });
    } else {
      setState(() => _status = '${_status ?? ''} (no compass)');
    }

    _ageTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    // Seed from last known only (do not treat as mark-quality).
    try {
      final last = await _sensors.lastKnownPosition();
      if (last != null && !stale() && _here == null) {
        setState(() {
          _here = last;
          if (!_busy) {
            _status = liveFixStatus(last.accuracy);
          }
        });
      }
    } catch (e) {
      debugPrint('Spot: last known position failed: $e');
    }

    if (!stale() && _status == 'Checking location…') {
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
      final ok = await _ensurePermissionsAndListen(
        interactive: true,
        openSettingsIfBlocked: true,
      );
      if (!ok) return;

      void onProgress(String msg, Position? latest) {
        if (!mounted) return;
        setState(() {
          _status = msg;
          if (latest != null) _here = latest;
        });
      }

      _diag.note('mark_start', forceAnyway ? 'mark anyway' : 'mark',
          accuracyM: _here?.accuracy);
      final custom = widget.collectMark;
      final result = custom != null
          ? await custom(forceWithBest: forceAnyway, onProgress: onProgress)
          : await collectPreciseMark(
              forceWithBest: forceAnyway,
              onProgress: onProgress,
              onGate: _diag.recordGate,
            );
      _diag.note(
        result == null ? 'mark_failed' : (result.forced ? 'mark_forced' : 'mark_locked'),
        result == null ? 'no usable samples' : '${result.sampleCount} samples',
        lat: result?.latitude,
        lon: result?.longitude,
        accuracyM: result?.accuracyMeters,
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
      _diag.setSpot(spot.latitude, spot.longitude);
      await HapticFeedback.heavyImpact();
      if (!mounted) return;
      final warning = result.accuracyWarning;
      setState(() {
        _spot = spot;
        _accuracyNote = warning;
        _status = result.forced
            ? 'Marked (provisional · ${formatAccuracyFeet(result.accuracyMeters)} · '
                '${result.sampleCount} ${result.sampleCount == 1 ? 'sample' : 'samples'})'
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
    _diag.setSpot(null, null);
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
              Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: _diag.enabled
                        ? TextButton(
                            key: const Key('openDiagnostics'),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => DiagnosticsScreen(log: _diag),
                              ),
                            ),
                            child: const Text('DIAG',
                                style: TextStyle(color: Color(0xFFFFAA33), fontWeight: FontWeight.w800)),
                          )
                        : null,
                  ),
                  const Expanded(
                    child: Text(
                      'SPOT',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFFFFCC00),
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        key: const Key('openSettings'),
                        tooltip: 'Settings',
                        icon: const Icon(Icons.settings, color: Colors.white54),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SettingsScreen(diagnostics: _diag),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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
              if (_accuracyNote != null) ...[
                const SizedBox(height: 4),
                Text(
                  _accuracyNote!,
                  key: const Key('accuracyNote'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFFAA33),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
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

/// Live status line for the current fix: Ready at the mark target,
/// Converging while fixes are usable for the weighted average, else Waiting.
String liveFixStatus(double accuracyMeters) {
  final acc = formatAccuracyFeet(accuracyMeters);
  if (accuracyMeters <= kReadyAccuracyMeters) return 'Ready · $acc';
  if (accuracyMeters <= kAcceptAccuracyMeters) return 'Converging · $acc';
  return 'Waiting for better fix · $acc';
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
