# NotchDeck

A menu-bar utility that turns the MacBook notch into an interactive hub: now-playing, a file shelf with AirDrop, widgets, live activities (battery, AirPods, timer, downloads, Focus), volume/brightness HUD replacement and two-finger gestures.

## Requirements

- macOS 14 Sonoma or later. Liquid Glass is used on macOS 26; older systems use `NSVisualEffectView`.
- Xcode 16 or later. Swift 6, strict concurrency.
- XcodeGen (`brew install xcodegen`) to regenerate the project from `project.yml`.
- Spotify desktop and/or Apple Music. Other music apps are not supported.

## Build and run

```bash
xcodegen generate
open NotchDeck.xcodeproj
```

Run the `NotchDeck` scheme. The app is an `LSUIElement` agent: no Dock icon, a menu-bar item instead. Unit tests live in `NotchDeckTests` (Swift Testing).

Command line:

```bash
xcodebuild -project NotchDeck.xcodeproj -scheme NotchDeck -destination 'platform=macOS' test
```

## Permissions

NotchDeck asks for these only when the feature needs them. Live status and deep links are in Settings → Permissions.

| Permission | Used for |
| --- | --- |
| Automation (Spotify, Music) | Reading and controlling playback via AppleScript |
| Calendars (full access) | Calendar widget |
| Focus status | Showing the current Focus and its icon |
| Screen & System Audio Recording | Real audio levels for the visualiser (falls back to play-state animation) |
| Accessibility / Input Monitoring | Media-key interception for the volume/brightness HUD |
| Files (Downloads) | Downloads live activity |
| Camera | Face Unlock scans and enrolment only (opt-in) |
| Accessibility | Face Unlock: typing the stored password into the lock screen (opt-in) |

Launch at login uses `SMAppService`. Updates use Sparkle.

## Signing and notarization

Release builds are Developer ID signed, hardened runtime on, App Sandbox off (AppleScript control and global mouse tracking need it). The WidgetKit extension is sandboxed and shares data with the app through the App Group `F63KU4246G.com.notchdeck.shared`.

One-time setup:

```bash
security find-identity -v -p codesigning
xcrun notarytool store-credentials notchdeck-notary --apple-id <apple-id> --team-id F63KU4246G
```

Build, sign, notarize, staple and package:

```bash
scripts/release.sh
```

Output: `build/release/NotchDeck-<version>.dmg`. Override `TEAM_ID`, `NOTARY_PROFILE` or `SIGN_ID` through the environment if needed.

## Known limitations

- **Lock screen:** macOS does not let third-party apps place content on the real lock screen. The WidgetKit extension (small, medium, large) is the substitute, for the desktop and Notification Center.
- **Screen recording indicator:** best effort. There is no public API; it detects the system recording UI and known recorders.
- **Focus toggle:** there is no public API to switch Focus. NotchDeck runs a user-installed Shortcut via `shortcuts run`; the Shortcut has to be created in Settings → Live activities.
- **Spotify likes:** AppleScript cannot save tracks. The heart uses the Spotify Web API with PKCE, and needs "Connect Spotify" in Settings. Tokens are stored in the Keychain.
- **HUD replacement:** some external displays do not expose brightness control. Those keys still show the system HUD.
- **Increase Contrast:** not yet honoured. Reduce Motion and Reduce Transparency are.
- **Profiling:** the performance budget (<1% idle CPU, <60 MB RAM) has not been measured with Instruments yet. See the QA checklist.

## Manual QA checklist

Run through these before each release:

- [ ] Notched Mac: notch open/close, dwell, expand/collapse animation
- [ ] Non-notched Mac: simulated pill at top centre opens and closes
- [ ] Two displays: "display with cursor" and "all displays" both behave
- [ ] Spotify only, Apple Music only, both running, neither running (empty state buttons open the app; disabled when not installed)
- [ ] Full-screen app: notch hidden when the setting is off, shown when on
- [ ] Sleep and wake, display hot-plug, Space change, Stage Manager
- [ ] Battery: plug, unplug, charging, full, low at 20% and 10%
- [ ] AirPods connect: name, icon, battery levels shown; hidden when unavailable
- [ ] Timer finishes: progress ring, flash, notification
- [ ] Downloads: `.crdownload` progress and completion tick; click reveals in Finder
- [ ] Shelf: drop files, folders, text, URLs; drag out; Quick Look; AirDrop
- [ ] Gestures: swipe next/previous, inversion, cooldown, no double triggers
- [ ] HUD: volume and brightness keys replaced; disabled toggle restores system HUD
- [ ] Settings → Accessibility: Reduce Motion and Reduce Transparency respected; VoiceOver reads controls in order
- [ ] Settings window opens to General by default
- [ ] Quit and relaunch: shelf, widgets and settings persist

## Lock screen player

An optional now-playing card and notch padlock shown above the macOS lock screen. Code lives in `NotchDeck/LockScreen/`.

### Platform reality

- macOS has **no public API** for lock screen UI. This feature uses private SkyLight (window server) space calls (`SLSMainConnectionID`, `SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSShowSpaces`, `SLSHideSpaces`, `SLSSpaceAddWindowsAndRemoveFromSpaces`, `SLSSpaceDestroy`), loaded with `dlopen`/`dlsym`. Nothing links against SkyLight.
- It can break on any macOS update, cannot ship on the Mac App Store and is distributed only as a Developer ID notarized download.
- Signatures come from public reverse-engineering write-ups of the `CGS`/`SLS` space calls. No GPL source was copied and no third-party library is used for this feature.
- **Scope:** the lock screen after you have logged in once (screen locked with ⌃⌘Q, or woken from sleep). The pre-login boot screen (FileVault / login window) is **not supported**: NotchDeck isn't running there.

### Fail-safe behaviour

- Any unresolved symbol: feature reports unsupported, logs once, `NullLockScreenPresenter` is used.
- Any failing call: the presenter tears down its space and windows and stays off for the rest of the session. The notch and desktop player keep working.
- Unlock notification, app quit, and a 2 s watchdog (polls `CGSessionCopyCurrentDictionary` while shown) always tear down the space and windows.
- Version gate: `LockScreenSupport.testedMajorVersions`. On other macOS majors the feature is labelled experimental and defaults to off.
- Kill switch: Settings → Lock Screen → "Turn Off and Remove Window".

### Privacy and threat review

- No network calls, no telemetry, nothing written to disk from this module; artwork and metadata stay in memory.
- No event taps. The only input observed is mouse-down **on NotchDeck's own lock-screen windows**, counted for the input diagnostic, and Esc delivered to NotchDeck itself (cancels a Face Unlock scan). Face Unlock *posts* keystrokes; see below.
- No screenshots of the lock screen.
- The card sits in the lower middle (below the clock, above the user name and password field), and the padlock pill covers only the notch. Neither overlaps the password field, Touch ID prompt, or the Sleep/Restart/Shut Down controls. The "Position" slider can move the card; keep it clear of those controls.
- "Song details" setting: show all, cover and controls only, or only "Now playing".

### Diagnostics and input spike

```bash
build/Build/Products/Debug/NotchDeck.app/Contents/MacOS/NotchDeck --lockscreen-diagnostics
```

This prints the macOS version, whether it's tested, symbol resolution and lock state, then exits.

Input test: Settings → Lock Screen → Diagnostics → "Show test window on next lock". Lock with ⌃⌘Q. A red test panel appears and shows its click count. Click it a few times, then unlock. Settings shows "Clicks received during last lock".

- Count > 0: input works and the card buttons control playback.
- Count 0: the card is display-only. Use the media keys (play/pause, next, previous). The music apps handle those keys.

Result on macOS 27.0.1: _pending, fill in after the first run_.

### Manual QA

- [ ] Lock with ⌃⌘Q while playing: padlock locks in notch, card fades in after ~0.35 s.
- [ ] Unlock with Touch ID and with password: card gone at once, padlock unlock animation in the notch.
- [ ] Quick lock/unlock: no card flash.
- [ ] Lid close/open, and display sleep/wake, while locked.
- [ ] Two displays: card on main display; hot-plug a display while locked.
- [ ] Spotify only, Music only, nothing playing (no card), paused ("Show when paused" on/off).
- [ ] Skip track from media keys while locked: cover cross-fades.
- [ ] Quit Spotify/Music while locked: card fades out.
- [ ] Feature disabled, kill switch while locked, Reduce Motion / Reduce Transparency / Increase Contrast, VoiceOver.
- [ ] After a macOS update: run `--lockscreen-diagnostics`, then add the major version to `testedMajorVersions` once this list passes.

## Face Unlock (software, camera-based)

Opt-in, off by default. On the lock screen, hover the notch (or click it, or wake the screen, per Settings), complete a random blink or head-turn prompt, and on a verified live match NotchDeck types your login password into the lock screen. Code lives in `NotchDeck/FaceUnlock/`.

### Risk statement

**This makes your Mac less secure than typing your password or using Touch ID.** Anyone who can fool the camera check, or who can read the stored password, can unlock this Mac. It is not Face ID: MacBook cameras are 2D with no depth sensor, so the liveness prompt stops photos but **not a video of you** that blinks or turns at the right moment. Use it only on a Mac that you alone use.

### Scope

- Works on the lock screen after you have logged in once (⌃⌘Q, sleep, lid close). It does **not** work on the boot-time login screen and does not bypass FileVault: your password is always needed after a restart.
- Private window-server calls (the lock screen presenter) and the keystroke entry method can break on any macOS update. On any error the feature turns itself off and the normal password / Touch ID path is untouched.

### How it works

| Part | What it does |
| --- | --- |
| `FaceCaptureService` | Built-in camera only, 640x480, running only during a scan; stops after it, on sleep, error, unlock and quit. The system camera indicator is never suppressed. |
| `FaceDetector`, `FaceGate` | Vision face rectangles (yaw/roll/pitch), landmarks and capture quality; requires exactly one centred, large, well-lit face. |
| `LivenessChecker` | Random challenge within 3 s: blink (eye aspect ratio) or turn left/right (yaw). Fails if the face leaves, a second face appears, or the face never moves. |
| `CoreMLFaceRecognizer`, `FaceMatcher` | FaceNet embeddings (512-d) of the frames taken **during** the liveness challenge; median of per-frame scores (mean of the 3 best template cosines) must reach the threshold (default 0.70). |
| `TemplateStore` | 15 embeddings (3 straight + 12 directions) from the Face ID-style enrolment ring. Numbers only, no photos. |
| `CredentialVault` | Login password, checked with OpenDirectory before it is stored and again before every use. |
| `CGEventLockScreenInput` | Types the password once with synthesised key events and presses Return; stops if the screen unlocks; never retries. |
| `FaceUnlockCoordinator` | State machine: `idle → armed → scanning → liveness → matching → unlocking → success / failure / lockedOut / disabled`. |

Face model: **FaceNet** (Inception-ResNet v1) from [facenet-pytorch](https://github.com/timesler/facenet-pytorch), VGGFace2 weights, 160x160 RGB input, 512-d output, converted to Core ML by `scripts/convert-facenet.py` (`NotchDeck/Resources/FaceNet.mlpackage`). Licences: facenet-pytorch code MIT; the VGGFace2-trained weights are for research / non-commercial use only. Fine for personal use; check before distributing.

### Safety rules

- 3 failed scans (liveness or match; configurable 1–10) lock Face Unlock out until one normal unlock. The count survives lock cycles. "No face" and cancels don't count.
- At most one scan per 2 s; 5 s after one failure, 30 s after two or more.
- A failed password entry, or a stored password that no longer verifies (you changed it), locks Face Unlock out at once: a wrong password is never typed twice.
- Refuses to run without a valid NotchDeck code signature (team F63KU4246G), a built-in camera, camera permission, or the face model. On an untested macOS major it is labelled experimental.
- Kill switch: Settings → Face Unlock → "Turn Off and Delete…", or the menu-bar item "Disable Face Unlock". Both wipe the password and face data.

### Setup

1. Settings → Face Unlock → turn it on (read the warning).
2. "Enrol Face and Password…": follow the ring (look straight, then move your head in a slow circle), then type your login password and Save.
3. Grant Camera and Accessibility when asked.
4. Lock with ⌃⌘Q and hover the notch.

Calibration: the enrolment window's "Calibrate" box shows a live match score. Your own face should score well above the threshold; another person well below. A photo of you scores like you: the liveness prompt, not the threshold, rejects photos.

### Data inventory and removal

| Data | Where | Leaves the Mac? |
| --- | --- | --- |
| Login password | Keychain, data-protection, access group `F63KU4246G.com.notchdeck.app.faceunlock`, `AfterFirstUnlockThisDeviceOnly`, not synced | Never; excluded from backups |
| Face embeddings (15 x 512 numbers) | Same keychain group, item `com.notchdeck.faceunlock.templates` | Never; excluded from backups |
| Failed-scan count | `defaults` key `faceUnlockFailures` | No |
| Settings | `defaults` keys `faceUnlock*` | No |

No photos are stored, the camera preview exists only in memory while enrolling, and there are no network calls or telemetry. The password is never logged, shown or put on the pasteboard; its bytes are zeroed after use (the String a text field and OpenDirectory need cannot be zeroed).

Remove everything: use the kill switch, then `defaults delete com.notchdeck.app` if you also want the settings gone. Deleting the app alone leaves the keychain items; use the kill switch first.

### Troubleshooting

- **Nothing happens on hover:** check Settings → Face Unlock → Diagnostics (camera, model, Accessibility, code signature) and the trigger setting.
- **"Use password" in the notch:** lockout after failed scans or a failed entry. Unlock once normally.
- **"Couldn't unlock. Use password":** the stored password no longer matches (you changed it) or Accessibility is off. Update it in the enrolment window.
- **Often "Not recognised":** re-enrol in the light you usually use, or lower Match strictness a little.
- Logs: `log show --last 10m --info --predicate 'subsystem == "com.notchdeck.app" AND category == "FaceUnlock"'` (state changes, scores and errors; never the password).
- Spike: `open -n NotchDeck.app --args --face-unlock-spike`, lock, hover, unlock; report in `~/Library/Logs/NotchDeck/face-unlock-spike.txt`. Result on macOS 27.0.1: camera, hover, keystroke entry and keychain reads all work on the lock screen.

### Manual QA

- [x] Enrol (ring, left/right and up/down directions).
- [x] Scan and unlock with your face (macOS 27.0.1).
- [x] Photo of you on a phone: rejected.
- [ ] Video of you on a phone: must be rejected; known weak point, record the result.
- [ ] Second person in view; another person alone.
- [ ] Dim and bright light; with and without glasses.
- [ ] Lock with ⌃⌘Q; lid close/open; sleep/wake (scan cancels, camera light off).
- [ ] Esc during a scan (may not reach NotchDeck on the lock screen; moving the cursor away always cancels).
- [ ] 3 failures: lockout, then one normal unlock resets it.
- [ ] Change your login password: next scan must not type the old one.
- [ ] Feature off; kill switch from the menu bar wipes data.
- [ ] After a macOS update: re-run the spike before trusting it.
