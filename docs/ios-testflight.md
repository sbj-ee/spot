# Spot iOS → TestFlight

Target: put a try-build on a family iPhone (TestFlight). Android APK path is unchanged.

## Identity

| Item | Value |
|------|--------|
| Bundle ID | `ee.sbj.spot` |
| Display name | Spot |
| Min iOS | **15.0** (required by Flutter 3.47+) |
| Location | When In Use only (precise) |
| Upload | **Only after** Apple Developer enrollment is active and Stephen confirms |

## One-time Apple / Xcode setup (MacBook Air)

1. Enroll in [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr) and wait until status is **Active**.
2. Install Xcode (App Store) + accept license; install CocoaPods if prompted (`sudo gem install cocoapods` or Homebrew).
3. Install Flutter and confirm: `flutter doctor` (Xcode + CocoaPods green).
4. Sign in to Xcode → Settings → Accounts with the Developer Apple ID.
5. Clone and open the iOS workspace:

```bash
git clone https://github.com/sbj-ee/spot.git
cd spot
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```

6. In Xcode: select **Runner** target → **Signing & Capabilities**:
   - Team: your personal/company Apple Developer team
   - Bundle Identifier: `ee.sbj.spot` (already set)
   - Automatically manage signing: on

## Build IPA

```bash
cd spot
flutter build ipa --release
# output under build/ios/ipa/
```

Or Archive from Xcode (Product → Archive).

## Upload to TestFlight (wait for enrollment yes)

**Do not upload** until Stephen confirms Developer enrollment is active.

1. Xcode Organizer → Distribute App → App Store Connect.
2. Or: `xcrun altool` / Transporter with the `.ipa`.
3. App Store Connect → create app if needed (bundle `ee.sbj.spot`).
4. TestFlight → Internal Testing → add daughter’s Apple ID → she installs **TestFlight** from the App Store → install Spot.

## Privacy strings (already in Info.plist)

- `NSLocationWhenInUseUsageDescription` — mark spot + arrow/distance
- `NSLocationTemporaryUsageDescriptionDictionary` / PreciseAccuracy — precise GPS for parking
- `NSMotionUsageDescription` — compass arrow

No Always location. No background tracking in v0.

## Min iOS

**15.0** — Flutter 3.47+ / Xcode 27 range. `ios/Podfile` sets `platform :ios, '15.0'`; Xcode `IPHONEOS_DEPLOYMENT_TARGET` matches.

## Blockers checklist

- [ ] Apple Developer enrollment **Active**
- [ ] Xcode Team selected for `ee.sbj.spot`
- [ ] First `flutter build ipa` succeeds on MacBook Air
- [ ] App Store Connect app + TestFlight invite (only after enrollment confirmed)
