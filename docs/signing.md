# Android release signing

Android only upgrades an app in place when the new APK is signed with the **same
certificate** as the installed one. Otherwise the Pixel refuses with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the app has to be uninstalled (losing its data).
This doc sets up one stable release key so every future build upgrades in place.

## Where things stand (Oct 2026)

Every APK built so far, including the installed **0.1.3+6**, is signed with an
auto-generated **Android Debug** key (`CN=Android Debug`), cert SHA-256:

```
DD:C2:53:21:EF:F3:EA:41:D3:34:1D:3A:4D:9C:71:37:59:9C:71:75:17:F3:5D:9A:9C:22:D6:A6:43:F7:CE:B2
```

That key is the build machine's `~/.android/debug.keystore`. Debug keystores are
created automatically per machine with a public, well-known password, so they're
not suitable as a release key: a different machine (or a wiped one) produces a
different key, which is exactly what broke the 0.1.3 upgrade.

## Recommendation

Generate a proper release key **once**, store it as repo secrets, and let the
Release workflow sign every build. The first release-key build needs **one final
uninstall** of the debug-signed 0.1.3+6; every build after that upgrades in place.

(Alternative: keep using the debug keystore that signed 0.1.3+6 as the "release"
key to avoid that uninstall. It works technically, but its password is public
(`android`) and it's tied to a debug identity; not recommended.)

## One-time setup (Stephen)

Run on a trusted machine. `keytool` comes with any JDK. Nothing below echoes a secret.

```sh
# 1. Create the keystore (prompts for passwords; use the same one for store and key)
mkdir -p ~/secure && cd ~/secure
keytool -genkeypair -v -keystore spot-release.jks -storetype PKCS12 \
  -alias spot -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Stephen B. Johnson, O=sbj-ee, C=US"

# 2. Back it up (password manager / offline). Losing it means another uninstall.

# 3. Put the password in a file without echoing it
read -rs -p "Keystore password: " PW; printf '%s' "$PW" > spot-ks-pass.txt; unset PW; echo
chmod 600 spot-ks-pass.txt

# 4. Create the repo secrets, reading every value from a file/stdin
base64 -w0 spot-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R sbj-ee/spot   # macOS: base64 -i spot-release.jks
gh secret set ANDROID_KEYSTORE_PASSWORD -R sbj-ee/spot < spot-ks-pass.txt
gh secret set ANDROID_KEY_PASSWORD      -R sbj-ee/spot < spot-ks-pass.txt
printf 'spot' | gh secret set ANDROID_KEY_ALIAS -R sbj-ee/spot

# 5. Remove the plaintext password file
rm -f spot-ks-pass.txt

# 6. Note the fingerprint for later checks
keytool -list -v -keystore spot-release.jks -alias spot | grep SHA256
```

## Releasing

Push a tag (`git tag v0.1.4 && git push origin v0.1.4`) or run **Release** from the
Actions tab. The workflow decodes the keystore, builds the APK and AAB, verifies the
APK with `apksigner`, prints only the signer cert SHA-256, and attaches
`spot-<version>.apk`, `.aab` and `SHA256SUMS` to the GitHub Release. If any secret
is missing it fails instead of shipping a debug-signed build. It does not run on PRs.

Before installing, confirm the fingerprint in the release notes matches the one
from step 6.

## Local builds

- Without signing config, `flutter build apk --release` signs with the machine's
  debug key (fine for local testing, won't upgrade a release-signed install).
- To sign locally with the release key, create `android/key.properties` (gitignored):

  ```properties
  storeFile=/absolute/path/to/spot-release.jks
  storePassword=...
  keyAlias=spot
  keyPassword=...
  ```

  or export `KEYSTORE`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
