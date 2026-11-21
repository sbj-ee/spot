import 'geo_math.dart';

/// Learns a steady compass error (a magnetic case, a car-mount plate, a
/// poorly calibrated sensor) by comparing the compass with the GPS
/// direction of travel while walking in a straight line.
///
/// The returned [offsetDeg] is added to the true-north compass heading.
/// It assumes the phone points the way you walk, which is how people hold
/// it while following the arrow; windows where the two disagree by more
/// than [maxObservedOffsetDeg] are treated as "phone not pointing forward"
/// and ignored.
class CompassOffsetEstimator {
  CompassOffsetEstimator({
    this.windowSize = 5,
    this.maxSpreadDeg = 12,
    this.maxObservedOffsetDeg = 40,
    this.maxAccuracyMeters = 15,
    this.maxCourseAccuracyDeg = 20,
    this.learnRate = 0.3,
    this.maxOffsetDeg = 30,
  });

  /// Consecutive qualifying GPS fixes (about one per second) per observation.
  final int windowSize;

  /// Course and compass-vs-course differences must each stay within this
  /// band across a window: walking straight, phone held steady.
  final double maxSpreadDeg;

  /// A larger difference means the phone isn't pointing where you walk.
  final double maxObservedOffsetDeg;

  /// Fixes less accurate than this give too noisy a course.
  final double maxAccuracyMeters;

  /// Platform-reported course accuracy, when it gives one (Android 8+).
  final double maxCourseAccuracyDeg;

  /// How far each observation moves the offset (the first moves it half way
  /// or this far, whichever is more).
  final double learnRate;

  /// The offset never grows past this.
  final double maxOffsetDeg;

  double _offset = 0;
  int _observations = 0;
  final List<double> _courses = [];
  final List<double> _deltas = [];

  /// Degrees to add to the compass heading.
  double get offsetDeg => _offset;

  /// Number of accepted walking windows so far.
  int get observations => _observations;

  /// Feeds one GPS fix. [courseDeg] is the GPS direction of travel (null
  /// when standing still) and [compassTrueDeg] the compass heading in true
  /// degrees before [offsetDeg] (null while it is uncalibrated). Returns
  /// true when the offset changed.
  bool addFix({
    required double? courseDeg,
    required double? compassTrueDeg,
    required double speedMps,
    required double accuracyMeters,
    double? courseAccuracyDeg,
  }) {
    final walking =
        speedMps.isFinite &&
        speedMps >= kMinCourseSpeedMps &&
        speedMps < kPreferCourseSpeedMps;
    final courseOk =
        courseAccuracyDeg == null ||
        !courseAccuracyDeg.isFinite ||
        courseAccuracyDeg <= 0 || // not reported
        courseAccuracyDeg <= maxCourseAccuracyDeg;
    if (courseDeg == null ||
        compassTrueDeg == null ||
        !walking ||
        !accuracyMeters.isFinite ||
        accuracyMeters > maxAccuracyMeters ||
        !courseOk) {
      _clearWindow();
      return false;
    }

    final delta = shortestAngleDelta(compassTrueDeg, courseDeg);
    if (delta.abs() > maxObservedOffsetDeg) {
      _clearWindow();
      return false;
    }
    _courses.add(courseDeg);
    _deltas.add(delta);
    if (_courses.length < windowSize) return false;

    final ok =
        _spread(_courses) <= maxSpreadDeg && _spread(_deltas) <= maxSpreadDeg;
    final observed = _deltas.reduce((a, b) => a + b) / _deltas.length;
    _clearWindow();
    if (!ok) return false;

    final rate = _observations == 0 && learnRate < 0.5 ? 0.5 : learnRate;
    _offset = (_offset + rate * (observed - _offset))
        .clamp(-maxOffsetDeg, maxOffsetDeg)
        .toDouble();
    _observations++;
    return true;
  }

  void _clearWindow() {
    _courses.clear();
    _deltas.clear();
  }

  /// Widest angular gap of [degs] from their first value, either side.
  static double _spread(List<double> degs) {
    var lo = 0.0, hi = 0.0;
    for (final d in degs) {
      final off = shortestAngleDelta(degs.first, d);
      if (off < lo) lo = off;
      if (off > hi) hi = off;
    }
    return hi - lo;
  }
}
