# Building this fork

App and login helper inherit `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`
from the project-level Debug/Release build settings. Both Info.plist files use
these settings; building no longer increments or rewrites their versions.

Increase the project build number when preparing a new installable build. It must
not be below the installed app or the saved `buildNumber` preference: the existing
startup compatibility check resets preferences on a downgrade. Restore the
matching preference backup when rolling back to an older build.

Run the hardware-free scheduler regression suite with:

```sh
python3 Tests/run-brightness-scheduler-tests.py
```

Build a universal Release app using Xcode and an available local signing identity:

```sh
xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -packageAuthorizationProvider netrc \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='<your team ID>' \
  CODE_SIGN_IDENTITY='Apple Development' build
```

The product is `build/DerivedData/Build/Products/Release/MonitorControl.app`.
Check the embedded login helper's version as well as the app's, and verify the
complete bundle with `codesign --verify --deep --strict --verbose=2` before using
it. A local development signature is not notarized public distribution.

Builds still run the existing SwiftFormat phase, which can format Swift sources.
Use a disposable source copy when validating without changing the checkout.

Preserve the current app and export its preferences before replacement. Do not
accept an official MonitorControl update as a fork update: the official binary
does not contain this fork's schedule, input-switching, or main-display features.
The official Sparkle feed is still configured and requires a separate fork update
policy before public distribution.

After installation, check manual brightness across sleep/wake, cable reconnect,
and switching away from/back to the Mac input. A manual adjustment lasts until
the next schedule event or a schedule settings edit within the current app
session. Confirm the next event applies its configured brightness, and check
volume, contrast, OSD, custom shortcuts, and input/main-display switching on the
actual monitor.
