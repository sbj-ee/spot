# Spot

Mark one GPS fix. Walk away. Follow a big arrow and distance back.

Android-first MVP for a Google Pixel 9 (Flutter). Product notes:
[Spot — mark & find GPS location](https://app.notion.com/p/3d72b260c3f081c4aa93e0998de97b44).

Public repo: https://github.com/sbj-ee/spot

## What v0.1.3 does

- Single high-contrast screen
- **Mark Spot** — high-accuracy GNSS mark (not the first cached fix):
  - Android: Play services fused provider, `PRIORITY_HIGH_ACCURACY`, 1 s updates, no distance filter
  - ~2s GPS warm-up, then an accuracy-weighted (1/σ²) average over the last 10 fixes ≤ ~15 m;
    locks when ≥5 samples and the weighted estimate is ≤ ~5 m (~16 ft)
  - While sampling shows live and averaged ±ft (`Sampling 3/5 · now ±20 ft · avg ±14 ft`)
  - After 25 s without a lock, saves the best estimate so far as **provisional**
  - Live **Ready / Converging / Waiting for better fix** with ±ft; Mark prompts **Mark anyway** if still weak
  - Discards coarse / jump outliers while sampling
- Live arrow = device compass heading vs bearing-to-spot
- Distance in **feet** under ~0.5 mi, else **miles**
- **Replace** / **Clear** (one spot only)
- Shows live GPS **±accuracy** and **fix age**
- Offline after mark (no map tiles, no account)

## Diagnostics (since 0.1.2, off by default)

Gear icon → **Diagnostics log**. Records every fix (accuracy, satellites
used/visible, speed, bearing, provider), every Mark gate decision, time to
first fix and to ±50/30/15/10/5 ft, and an A/B walk test against the saved
spot. Export as CSV or JSON via the share sheet. Field test steps:
[docs/diagnostics-field-test.md](docs/diagnostics-field-test.md).

## Non-goals (v0)

No cloud, no multi-spot list, no turn-by-turn, no AR. iOS TestFlight packaging is in progress (see [docs/ios-testflight.md](docs/ios-testflight.md)).

## iOS (TestFlight) — MacBook Air

Bundle id: `ee.sbj.spot`. Min iOS **15.0** (Flutter 3.47). Full steps: [docs/ios-testflight.md](docs/ios-testflight.md).

Short version (after Apple Developer enrollment is **active** — do not upload until then):

```bash
git clone https://github.com/sbj-ee/spot.git && cd spot
flutter pub get
open ios/Runner.xcworkspace   # Xcode: Runner → Signing & Capabilities → Team = your Apple Developer team
flutter build ipa --release
# Then Xcode Organizer → Distribute App → App Store Connect → TestFlight
# Invite daughter via TestFlight Internal Testing
```

## Install on Pixel 9

Prefer reinstall over the existing install:

```bash
adb install -r app-release.apk
```

### A. Sideload release APK

1. Download `app-release.apk` from [Releases](https://github.com/sbj-ee/spot/releases).
2. Or with USB debugging (Developer options on): `adb install -r app-release.apk`
3. Open **Spot** → grant **precise location**. Wave the phone in a figure-8 if the compass says calibrating.
4. Stand outdoors, wait until status shows **Ready** (±16 ft or better), then **MARK SPOT**.

### B. USB debug with Flutter

```bash
git clone https://github.com/sbj-ee/spot.git
cd spot
flutter pub get
flutter devices
flutter run --release
```

### Build APK yourself

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

## Known limits

- Indoor / underground parking: GPS accuracy will spike; trust the ±ft readout and wait for Ready outdoors.
- First few seconds after Mark can still warm the GNSS radio — let it finish sampling.
- Compass near cars/metal can skew; step a few feet away when marking if the arrow feels wrong.
- No background tracking with screen off in v0.
- One spot only (by design).

## Stack

Flutter + `geolocator` + `flutter_compass` + `shared_preferences`.
