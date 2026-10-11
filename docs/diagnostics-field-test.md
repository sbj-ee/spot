# Spot diagnostics: driveway A-to-B test

This build (0.1.2) records what the GPS reports and what Spot decides, so
we can see why Mark is slow or stuck around ±30 ft. It does **not** change
how Mark works. Diagnostics is **off** unless you turn it on.

## 1. Install

1. On the Pixel, open the GitHub release page for **v0.1.2-diag** and tap
   `app-release.apk` to download it.
2. Open the download. If Android asks, allow your browser to install apps.
3. Tap **Update**. It installs over 0.1.1. Your saved spot is kept.
   (If it says "App not installed" or a signature conflict, stop and tell me.
   Do **not** uninstall the old app.)

## 2. Turn on diagnostics

1. Open Spot. Tap the **gear** at top right.
2. Turn on **Diagnostics log**. The screen will now stay on while Spot is open.
3. Go back. An orange **DIAG** button is now at top left.

## 3. Run the test outdoors (driveway)

Pick point **A**: something you can stand on exactly again, like a crack or
a chalk mark on the driveway. Pick point **B** about 100 ft away.

1. **Fully close Spot** (swipe it away from recent apps), then open it again
   while standing on A. This starts a fresh timing for "first fix" and
   "time to ±30 ft" etc.
2. Stand still on A, phone held flat in front of you. Wait about a minute,
   watching the status line. Don't tap anything yet.
3. Tap **MARK SPOT** (or **Mark anyway** if it asks). Wait until it says
   Marked. If you already had a spot, tap **REPLACE SPOT** instead.
4. Tap **DIAG**. Scroll to **A/B walk test**.
5. Tap **1 · On A**. Stand still about 30 seconds.
6. Tap **2 · Walking** and walk to B.
7. At B, tap **3 · At B**. Stand still about 30 seconds.
8. Walk back to exactly the same spot A. Tap **4 · Back on A**.
   Stand still about 60 seconds. The screen shows the "Back-at-A error".
9. Tap **Finish**.

Keep Spot open on screen the whole time. If the phone locks or you switch
apps, the GPS stops and the log has a gap; just carry on.

Optional: do the same test once indoors near a window, so we can compare.

## 4. Export and send it back

1. On the DIAG screen, scroll down and tap **Export CSV**.
2. The Android share sheet opens. Pick **Gmail** and send it to yourself,
   or pick **Drive** and save it.
3. Tap **Export JSON** and send that too, the same way.
4. Reply to the thread with the files attached (or say which Drive folder
   they're in). Mention roughly where you stood and whether it was clear sky.

You can tap **Clear log** before a new run. Turn diagnostics off again in
the gear menu when you're done; nothing is sent anywhere on its own.

## What is in the file

One row per event: each GPS fix (time, lat, lon, accuracy, satellites used /
visible, speed, bearing, provider), each Mark decision (accepted / rejected
and why, with the averaging window size), first-fix and ±50/30/15/10/5 ft
times, and A/B phase changes with distance from the saved spot. The JSON
also has phone model, Android version and GNSS chip info.

Note: Android does not tell the app which provider produced each fix. The
"provider" column is the provider the build requests: 0.1.2 uses
LocationManager's `fused` provider (`forceLocationManager`), 0.1.3 uses
Google Play services' FusedLocationProviderClient.

## Comparing 0.1.2 and 0.1.3

Run the same test on 0.1.2 (baseline) and then on 0.1.3 (the fix), from
the same spot A, back to back if you can. 0.1.3 installs over 0.1.2 the
same way and keeps the diagnostics setting.
