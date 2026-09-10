# Spot

Mark one GPS fix. Walk away. Follow a big arrow and distance back.

Android-first MVP for a Google Pixel 9 (Flutter). Product notes:
[Spot — mark & find GPS location](https://app.notion.com/p/3d72b260c3f081c4aa93e0998de97b44).

Public repo: https://github.com/sbj-ee/spot

## What v0 does

- Single high-contrast screen
- **Mark Spot** — saves lat/lon, accuracy, timestamp (local only)
- Live arrow = device compass heading vs bearing-to-spot
- Distance in **feet** under ~0.5 mi, else **miles**
- **Replace** / **Clear** (one spot only)
- Shows live GPS **±accuracy** and **fix age** (parking garages will look weak — that is honest, not a bug)
- Offline after mark (no map tiles, no account)

## Non-goals (v0)

No cloud, no multi-spot list, no turn-by-turn, no AR, no iOS TestFlight yet (iOS folder is scaffolded for later).

## Install on Pixel 9

### A. Sideload release APK (easiest)

1. On the Pixel: **Settings → Apps → Special app access → Install unknown apps** — allow your browser/Files.
2. Download the latest `app-release.apk` from this repo’s [Releases](https://github.com/sbj-ee/spot/releases) (or copy `build/app/outputs/flutter-apk/app-release.apk` if you built locally).
3. Open the APK → Install → Open **Spot**.
4. Grant **precise location** when asked. Wave the phone in a figure-8 if the compass says calibrating.

### B. USB debug with Flutter

```bash
git clone https://github.com/sbj-ee/spot.git
cd spot
flutter pub get
# enable Developer options + USB debugging on the Pixel, plug in
flutter devices
flutter run --release
```

### Build APK yourself

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

## Known limits

- Indoor / underground parking: GPS accuracy will spike; trust the ±ft readout.
- Compass near cars/metal can skew; step a few feet away when marking if the arrow feels wrong.
- No background tracking with screen off in v0.
- One spot only (by design).

## Stack

Flutter + `geolocator` + `flutter_compass` + `shared_preferences`.
