# Spot

Mark one GPS fix. Walk away. Follow a big arrow and distance back.

Android-first MVP for a Google Pixel 9 (Flutter). Product notes:
[Spot — mark & find GPS location](https://app.notion.com/p/3d72b260c3f081c4aa93e0998de97b44).

Public repo: https://github.com/sbj-ee/spot

## What v0.1.1 does

- Single high-contrast screen
- **Mark Spot** — high-accuracy GNSS mark (not the first cached fix):
  - `LocationAccuracy.bestForNavigation` + Android LocationManager (`forceLocationManager`)
  - ~2s GPS warm-up, then average ≥5 samples with horizontal accuracy ≤ ~5 m (~16 ft)
  - Live **Ready / Waiting for better fix** with ±ft; Mark prompts **Mark anyway** if still weak
  - Discards coarse / jump outliers while sampling
- Live arrow = device compass heading vs bearing-to-spot
- Distance in **feet** under ~0.5 mi, else **miles**
- **Replace** / **Clear** (one spot only)
- Shows live GPS **±accuracy** and **fix age**
- Offline after mark (no map tiles, no account)

## Non-goals (v0)

No cloud, no multi-spot list, no turn-by-turn, no AR, no iOS TestFlight yet (iOS folder is scaffolded for later).

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
