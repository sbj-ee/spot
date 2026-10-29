# Changelog

## 0.2.0+9 (2026-10-29)

### Added
- **Signed in-app updates (Android).** Settings > *Check for updates…* looks
  up the latest GitHub release and offers Install / Skip this version /
  Later. Install downloads `SHA256SUMS` and `SHA256SUMS.minisig`, verifies
  the minisign signature against the public key built into the app (release
  key DBC46B23C3AF0EF3, as in zwriter/zedit), checks the APK's SHA-256
  against the signed list, then hands the APK to Android's package installer
  (which asks you and checks it is signed with Spot's certificate). Unsigned
  or tampered releases are refused.
- Settings > *Check for updates at startup* toggle. **Off by default**: Spot
  stays offline unless you check or turn this on.
- New permissions: `INTERNET` (update check/download only) and
  `REQUEST_INSTALL_PACKAGES` (hand-off to the installer).

### Release
- The release workflow signs `SHA256SUMS` with minisign from the
  `MINISIGN_SECRET_KEY` / `MINISIGN_PASSWORD` secrets and verifies it against
  the embedded key before publishing.

### Tests
- BLAKE2b, Ed25519 (RFC 8032) and minisign against real minisign output;
  download/verify flow (tampered APK, tampered SHA256SUMS, wrong key,
  unsigned release, off-repo URL); Settings and dialog widget tests with
  headless screenshots in docs/screenshots/.
- CI now also builds a debug APK, so the Kotlin installer hand-off compiles.

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
