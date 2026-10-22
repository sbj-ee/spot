# Changelog

## 0.1.5+8 (2026-10-21)

### Fixed
- Arrow pointed the wrong way while driving. At 3 m/s (~7 mph) or faster the
  arrow now follows the GPS direction of travel ("· by direction of travel")
  instead of the compass, which in a car reads the phone's angle in its mount
  and is pulled off by the car's steel and magnetic mounts.
- Compass readings flutter_compass flags as unreliable are ignored; the arrow
  falls back to the GPS course, or shows the calibration hint.

### Tests
- Heading choice (fast uses course, slow uses compass), unreliable-compass
  filter, and bearing checks against known coordinate pairs.

## 0.1.4+7
- See the v0.1.4 release on GitHub.
