import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'geo_math.dart';
import 'precise_mark.dart';
import 'sensors.dart';
import 'spot_store.dart';

/// A fix older than this no longer counts as live (GPS lost, e.g. indoors).
const Duration _kStaleFixAge = Duration(seconds: 10);

/// How long the last GPS course keeps steering the arrow after you stop.
const Duration _kCourseHold = Duration(seconds: 5);

/// Compass changes smaller than this don't redraw the arrow.
const double _kHeadingRedrawDeg = 0.5;

/// How long a mark result stays on the status line before live GPS returns.
const Duration _kStatusHold = Duration(seconds: 6);

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
  });

  final SpotSensors sensors;
  final SpotStore? store;

  /// Override for tests; defaults to [collectPreciseMark] fed by [sensors].
  final PreciseMarkCollector? collectMark;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final SpotStore _store = widget.store ?? SpotStore();

  SavedSpot? _spot;
  Position? _here;

  /// When [_here] arrived on this device (fix timestamps use the GNSS clock).
  DateTime? _hereAt;

  /// Smoothed compass heading, true north (0 = north). A notifier so the
  /// ~30 Hz compass only rebuilds the arrow, not the whole screen.
  final ValueNotifier<double?> _heading = ValueNotifier<double?>(null);

  /// Smoothed heading as the compass reports it, before [_headingCorrection].
  double? _rawHeadingDeg;

  /// Added to the raw compass heading to get true north (see
  /// [SpotSensors.headingCorrection]); 0 until the first fix resolves it.
  double _headingCorrection = 0;
  bool _headingCorrectionRequested = false;
  bool _hasCompass = true;

  /// Last GPS direction of travel, used when the compass has no heading.
  double? _courseDeg;
  DateTime? _courseAt;

  /// Message shown instead of the live GPS line (progress, errors, mark
  /// confirmation). Null shows the live line built from [_here].
  String? _status;

  /// Running while [_status] is held on screen even though fixes keep coming.
  Timer? _statusHold;

  /// Sticky warning from the last mark (approximate location / failed
  /// precise-accuracy check). Live GPS updates rewrite [_status], so this is
  /// shown on its own line until the next mark.
  String? _accuracyNote;
  bool _busy = false;

  /// True from the Mark tap until sampling starts (permission + dialog).
  bool _markPending = false;
  bool _keepAwake = false;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<double?>? _compassSub;
  Timer? _ageTick;

  /// False while the app is hidden/paused; sensors are stopped then.
  bool _foreground = true;

  /// Bumped on every start/stop so a slow async start that finishes after
  /// the app went to the background doesn't attach listeners.
  int _sensorGeneration = 0;

  SpotSensors get _sensors => widget.sensors;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSensors();
    _statusHold?.cancel();
    _heading.dispose();
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
    _setKeepAwake(false);
  }

  /// Sets the status override; call inside setState. With [hold] the message
  /// survives incoming fixes for that long, then the live GPS line returns.
  void _putStatus(String? msg, {Duration? hold}) {
    _statusHold?.cancel();
    _statusHold = null;
    _status = msg;
    if (msg != null && hold != null) {
      _statusHold = Timer(hold, () {
        _statusHold = null;
        if (mounted) setState(() => _status = null);
      });
    }
  }

  void _onCompass(double raw) {
    final smoothed = smoothHeading(_rawHeadingDeg, raw);
    _rawHeadingDeg = smoothed;
    final trueDeg = normalizeDegrees(smoothed + _headingCorrection);
    final shown = _heading.value;
    if (shown == null ||
        shortestAngleDelta(shown, trueDeg).abs() >= _kHeadingRedrawDeg) {
      _heading.value = trueDeg;
    }
  }

  /// Resolves the true-north correction once; it barely changes over the
  /// distances this app covers.
  Future<void> _loadHeadingCorrection(Position pos) async {
    if (_headingCorrectionRequested) return;
    _headingCorrectionRequested = true;
    try {
      final deg = await _sensors.headingCorrection(
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: pos.altitude,
      );
      if (deg.isFinite) _headingCorrection = deg;
    } catch (e) {
      debugPrint('Spot: heading correction failed: $e');
    }
  }

  bool get _fixStale {
    final at = _hereAt;
    return at != null && DateTime.now().difference(at) > _kStaleFixAge;
  }

  bool get _fixReady {
    final here = _here;
    return here != null && !_fixStale && here.accuracy <= kReadyAccuracyMeters;
  }

  double? _distanceToSpot() {
    final here = _here;
    final spot = _spot;
    if (here == null || spot == null) return null;
    return Geolocator.distanceBetween(
      here.latitude,
      here.longitude,
      spot.latitude,
      spot.longitude,
    );
  }

  /// Close enough that the arrow would only be chasing GPS noise.
  bool _withinArrival(double distanceM) =>
      distanceM <=
      arrivalRadiusMeters(_here!.accuracy, _spot!.accuracyMeters);

  /// Screen stays on only while there is a spot to walk back to, so the
  /// phone still sleeps normally right after marking and once you arrive.
  void _syncKeepAwake() {
    final distanceM = _distanceToSpot();
    _setKeepAwake(
      _foreground && distanceM != null && !_withinArrival(distanceM),
    );
  }

  void _setKeepAwake(bool on) {
    if (on == _keepAwake) return;
    _keepAwake = on;
    _sensors.setKeepAwake(on);
  }

  /// Heading currently steering the arrow from the compass (for tests).
  @visibleForTesting
  double? get compassHeadingDeg => _heading.value;

  /// True while the background sensors are attached (exposed for tests).
  @visibleForTesting
  bool get sensorsActive => _posSub != null || _ageTick != null;

  Future<void> _bootstrap() async {
    final spot = await _store.load();
    if (!mounted) return;
    setState(() => _spot = spot);
    _syncKeepAwake();
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

    if (!_busy && _posSub == null) {
      setState(() => _putStatus('Checking location…'));
    }

    final serviceOn = await _sensors.isLocationServiceEnabled();
    if (stale()) return false;
    if (!serviceOn) {
      setState(() => _putStatus('Turn on Location / GPS'));
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
      setState(() => _putStatus('Location permission required · tap Mark to open Settings'));
      if (openSettingsIfBlocked) await _sensors.openAppSettings();
      return false;
    }

    // Already streaming (e.g. Mark while the screen is live): keep it.
    // Re-subscribing churns the platform GNSS/NMEA listeners for nothing.
    if (_posSub != null) return true;

    _posSub = _sensors.positionStream().listen((pos) {
      if (!mounted) return;
      setState(() {
        _here = pos;
        _hereAt = DateTime.now();
        final course = courseOverGround(
          speedMps: pos.speed,
          headingDeg: pos.heading,
        );
        if (course != null) {
          _courseDeg = course;
          _courseAt = _hereAt;
        }
        // Fixes are flowing, so the live GPS line takes over, unless the
        // mark flow owns the status or a message is being held.
        if (!_busy && _statusHold == null) _status = null;
      });
      _syncKeepAwake();
      _loadHeadingCorrection(pos);
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() => _putStatus('GPS error: $e'));
    });

    final compass = _sensors.headings();
    if (compass != null) {
      _compassSub = compass.listen((h) {
        if (!mounted || h == null) return;
        _onCompass(h);
      });
    } else {
      _hasCompass = false;
      setState(() => _putStatus('${_status ?? ''} (no compass)'));
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
          _hereAt = last.timestamp;
          if (!_busy) _putStatus(null); // live line shows its real age
        });
        _syncKeepAwake();
      }
    } catch (e) {
      debugPrint('Spot: last known position failed: $e');
    }

    if (!stale() && _status == 'Checking location…') {
      setState(() => _putStatus('Waiting for GPS…'));
    }
    return true;
  }

  Future<void> _markSpot({bool forceAnyway = false}) async {
    if (_busy || _markPending) return;
    _markPending = true;
    try {
      // Permission first: without it there is no fix, and the weak-GPS
      // dialog would stand between the user and the Settings jump.
      final ok = await _ensurePermissionsAndListen(
        interactive: true,
        openSettingsIfBlocked: true,
      );
      if (!ok || !mounted) return;

      if (!forceAnyway && !_fixReady) {
        final here = _here;
        final String detail;
        if (here == null) {
          detail = 'No fix yet. Wait outdoors with a clear sky, or mark with a weaker fix.';
        } else if (_fixStale) {
          detail = 'No fresh GPS (last fix ${formatFixAge(_hereAt)}). '
              'Wait for Ready, or mark anyway.';
        } else {
          detail = 'Current accuracy ${formatAccuracyFeet(here.accuracy)} (want ≤ ±16 ft). '
              'Wait for Ready, or mark anyway.';
        }
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('GPS not ready', style: TextStyle(color: Colors.white)),
            content: Text(detail, style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Wait')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'anyway'),
                child: const Text('Mark anyway', style: TextStyle(color: Color(0xFFFFCC00))),
              ),
            ],
          ),
        );
        if (choice != 'anyway' || !mounted) return;
        forceAnyway = true;
      }

      setState(() {
        _busy = true;
        _putStatus('Warming up GPS…');
      });

      final collect = widget.collectMark ?? _collectFromSensors;
      final result = await collect(
        forceWithBest: forceAnyway,
        onProgress: (msg, latest) {
          if (!mounted) return;
          setState(() {
            _putStatus(msg);
            if (latest != null) {
              _here = latest;
              _hereAt = DateTime.now();
            }
          });
        },
      );

      if (result == null) {
        if (!mounted) return;
        setState(
          () => _putStatus(
            forceAnyway
                ? 'Mark failed: no usable GPS samples'
                : 'Mark failed: fix too weak · try again',
            hold: _kStatusHold,
          ),
        );
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
      final warning = result.accuracyWarning;
      setState(() {
        _spot = spot;
        _accuracyNote = warning;
        _putStatus(
          result.forced
              ? 'Marked (best available · ${formatAccuracyFeet(result.accuracyMeters)})'
              : 'Marked · ${formatAccuracyFeet(result.accuracyMeters)} · ${result.sampleCount} samples',
          hold: _kStatusHold,
        );
      });
      _syncKeepAwake();
    } catch (e) {
      if (!mounted) return;
      setState(() => _putStatus('Mark failed: $e', hold: _kStatusHold));
    } finally {
      _markPending = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Default collector: samples the same sensor seam as the live screen.
  Future<PreciseMarkResult?> _collectFromSensors({
    required void Function(String status, Position? latest) onProgress,
    bool forceWithBest = false,
  }) => collectPreciseMark(
    onProgress: onProgress,
    forceWithBest: forceWithBest,
    positions: _sensors.positionStream(),
  );

  Future<void> _clearSpot() async {
    await _store.clear();
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _spot = null);
    _syncKeepAwake();
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

    final distanceM = _distanceToSpot();
    double? bearingDeg;
    if (here != null && spot != null) {
      bearingDeg = Geolocator.bearingBetween(
        here.latitude,
        here.longitude,
        spot.latitude,
        spot.longitude,
      );
    }

    final gpsStale = _fixStale;
    final gpsReady = _fixReady;
    final gpsWeak = here != null && here.accuracy > 30; // ~100 ft
    final accLabel = formatAccuracyFeet(here?.accuracy);
    // A stale fix can't tell us we've arrived; keep showing the arrow then.
    final arrived =
        distanceM != null && !gpsStale && _withinArrival(distanceM);

    // Direction of travel stands in while the compass has no heading.
    final courseAt = _courseAt;
    final courseDeg =
        courseAt != null &&
            !gpsStale &&
            DateTime.now().difference(courseAt) <= _kCourseHold
        ? _courseDeg
        : null;
    final String headingNote;
    if (_heading.value != null) {
      headingNote = '';
    } else if (courseDeg != null) {
      headingNote = ' · by direction of travel';
    } else {
      headingNote = ' · no compass';
    }
    final String arrowHint;
    if (here == null) {
      arrowHint = 'Waiting for GPS…';
    } else if (!_hasCompass) {
      arrowHint = 'Walk a few steps\n(no compass · arrow follows your direction)';
    } else {
      arrowHint = 'Point phone forward\n(compass calibrating)';
    }

    final altHint = here == null || spot == null || gpsStale
        ? null
        : altitudeHint(
            spotAltitudeMeters: spot.altitudeMeters,
            hereAltitudeMeters: here.altitude,
            hereAltitudeAccuracyMeters: here.altitudeAccuracy,
          );

    final String statusText;
    final Color statusColor;
    if (_status != null) {
      statusText = _status!;
      statusColor = Colors.white70;
    } else if (here == null) {
      statusText = 'Waiting for GPS…';
      statusColor = Colors.white70;
    } else if (gpsStale) {
      statusText = 'No fresh GPS · last fix ${formatFixAge(_hereAt)} · $accLabel';
      statusColor = const Color(0xFFFF6666);
    } else {
      statusText =
          '${gpsReady ? 'Ready' : 'Waiting for better fix'} · $accLabel${gpsWeak ? ' · WEAK' : ''}';
      statusColor = gpsWeak
          ? const Color(0xFFFF6666)
          : (gpsReady ? const Color(0xFF66FF99) : Colors.white70);
    }

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
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: statusColor,
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
                              child: arrived
                                  ? const _Arrived()
                                  : ValueListenableBuilder<double?>(
                                      valueListenable: _heading,
                                      builder: (context, compassDeg, _) {
                                        final headingDeg = compassDeg ?? courseDeg;
                                        return _Arrow(
                                          relativeDeg:
                                              headingDeg == null || bearingDeg == null
                                              ? null
                                              : shortestAngleDelta(headingDeg, bearingDeg),
                                          hint: arrowHint,
                                        );
                                      },
                                    ),
                            ),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              distanceM == null ? '—' : formatDistance(distanceM),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 64,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            bearingDeg == null
                                ? ''
                                : 'Bearing ${bearingDeg.round()}° ${bearingCardinal(bearingDeg)}$headingNote',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54, fontSize: 16),
                          ),
                          if (altHint != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              altHint,
                              key: const Key('altitudeHint'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white54, fontSize: 16),
                            ),
                          ],
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
        // Long labels and large system fonts shrink instead of wrapping.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1),
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatefulWidget {
  const _Arrow({required this.relativeDeg, required this.hint});

  /// Turn from where the phone points to the spot; null when unknown.
  final double? relativeDeg;

  /// Shown instead of the arrow while [relativeDeg] is null.
  final String hint;

  @override
  State<_Arrow> createState() => _ArrowState();
}

class _ArrowState extends State<_Arrow> {
  /// Unwrapped rotation, so 350° → 10° turns 20° forward instead of
  /// spinning 340° back.
  late double _turns = (widget.relativeDeg ?? 0) / 360;

  @override
  void didUpdateWidget(covariant _Arrow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.relativeDeg;
    if (next == null) return;
    final prev = oldWidget.relativeDeg;
    _turns = prev == null
        ? next / 360
        : _turns + shortestAngleDelta(prev, next) / 360;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.relativeDeg == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.explore_off, color: Colors.white24, size: 96),
          const SizedBox(height: 8),
          Text(widget.hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 16)),
        ],
      );
    }
    return Semantics(
      label: 'Spot is ${turnDescription(widget.relativeDeg!)}',
      child: AnimatedRotation(
        turns: _turns,
        duration: const Duration(milliseconds: 120),
        child: CustomPaint(
          size: const Size(220, 220),
          painter: _ArrowPainter(),
        ),
      ),
    );
  }
}

/// Shown instead of the arrow once the spot is within GPS error.
class _Arrived extends StatelessWidget {
  const _Arrived();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.place, color: Color(0xFFFFCC00), size: 120),
        SizedBox(height: 8),
        Text(
          "YOU'RE HERE",
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFFFFCC00),
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Look around · this is as close as GPS gets',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 16),
        ),
      ],
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
