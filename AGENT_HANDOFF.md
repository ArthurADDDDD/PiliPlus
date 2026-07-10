# Agent Handoff

This file is for the next agent. It intentionally describes only unfinished work and the desired user-visible result. Do not treat this file as an implementation plan.

## User Goal

The user wants a comfortable personal Android build of PiliPlus for Pixel 10 Pro on Android 17.

The app should still feel like normal PiliPlus/Bilibili usage. Do not remove normal user-facing features just to save power. SponsorBlock/空降助手 must remain available.

## Finished Enough For Now

- Android 17/Tensor power-saving refresh-rate switch exists.
- System native PiP still works when going home/background.
- Dragging system PiP to the Android close target should pause playback.
- Background playback, lock-screen listening, and PiP listening should not be made worse by power-saving defaults.
- Settings switches were added for the new Android/PiP behavior.

## Not Finished

### 1. Back Navigation + Native PiP (implemented via PipShell, needs on-device validation)

History: the in-app mini player (Route A) was implemented first but rejected
by the user, who wants true system-native PiP. Final approach ("Route C",
2026-07-08): a native PiP shell activity + libmpv surface hot-swap.

- Back while playing → video page pops normally; a native `PipActivity`
  launches directly into system PiP (`ActivityOptions.makeLaunchIntoPip`,
  API 33+); the libmpv output `wid` is hot-swapped from the Flutter texture
  to the PipActivity TextureView. Playback is NOT rebuilt — no rebuffering.
- System-native PiP window: native resize/corners/drag/dismiss, rewind /
  play-pause / fast-forward RemoteActions via the media session.
- Expand → output swaps back to the Flutter texture and the video page is
  re-pushed seamlessly. Dismiss → progress heartbeat + player disposed.
- Trade-off: no danmaku inside the PiP window (danmaku is Flutter-rendered).
- Settings: `返回键进入原生画中画` (default on); `返回时小窗播放` kept as
  fallback (default off; only used when the native switch is off).
- Key files: `android/.../PipActivity.kt`, `lib/plugin/pl_player/pip_shell.dart`,
  `AndroidHelper.buildPipParams/pipShellActivity`, `MainActivity.channel`.

What remains: on-device validation (see TODO.md P0 checklist).

**2026-07-10 update**: the surface-swap-on-reload freeze described above
(quality/episode switch during PiP re-attaching output to the Flutter
texture, or leaving it detached, freezing the PiP window) has been fixed
at the code level, not yet validated on-device. Root cause: PiliPlus'
`_initPlayer()` configures `androidAttachSurfaceAfterVideoParameters:
false`, which made `AndroidVideoController.onLoadHooks` unconditionally
re-attach the *internal* Flutter `wid` on every media reload — completely
bypassing the old `externalSurfaceActive` flag (which was only checked in
the `videoParams` listener, not in `onLoadHooks`). Fix: replaced the single
static bool with a real external-surface-ownership state machine on
`AndroidVideoController` (`third_party/media_kit_video`):
`attachExternalSurface` / `updateExternalSurfaceSize` /
`detachExternalSurfaceAndRestoreInternal` / `releaseExternalSurface`, backed
by a pure, unit-tested `ExternalSurfaceOwnership` + `LoadGeneration` class
(`android_video_controller/external_surface_ownership.dart`, 56 offline
tests in `third_party/media_kit_video/test/`). `onUnloadHooks` now marks a
"reattach pending" flag instead of losing ownership; `onLoadHooks` and the
`videoParams` listener re-attach the *current* external surface (never a
stale cached `wid`) once the reload completes; expand-time restore always
uses the controller's live internal `_wid`, not a value cached before PiP
started. `pip_shell.dart` was rewired to this new API. Needs on-device
validation: quality switch / episode switch / collection switch while in
PiP should now update smoothly instead of freezing (see TODO.md for the
specific checklist).

### 2. PiP Interaction Quality

Desired effect:

- PiP should be system-native, not a custom grey floating overlay.
- PiP should show danmaku by default.
- PiP controls should include pause/play and seek backward/forward where Android supports them.
- PiP should be resizable using native Android PiP behavior.
- PiP should not get stuck at a screen edge.
- Dragging PiP to the system close target should close PiP and pause playback.
- Returning from PiP should not leave audio/video playing unexpectedly in the background.

### 3. Pixel/Tensor Power Validation

Desired effect:

- Long playback on Pixel 10 Pro should be cooler and less power hungry than the original behavior.
- The optimization must not make daily use uncomfortable.
- Lock-screen music/video listening should still work.
- Background playback should still work.
- PiP listening should still work.

Still needs validation:

- Long-session temperature trend.
- Battery drain with the 60Hz switch on and off.
- Frame smoothness and dropped frames.
- Decoder behavior for 720P, 1080P, 4K, and HDR.
- Wi-Fi and cellular playback cases.

### 4. Settings Polish

Desired effect:

- User-visible switches should describe behavior honestly.
- Experimental or incomplete behavior should be clearly marked or hidden.
- Power-saving defaults should be easy to disable.
- User-chosen settings should not be overwritten except to disable known-bad experimental behavior.

### 5. Power/thermal instrumentation (tool finished, needs Pixel 10 Pro measurements)

`tools/monitor_piliplus_power.py` (stdlib-only, no root, adb-based) and
`docs/POWER_TEST_GUIDE.md` (a 7-scenario test matrix designed to separate
screen-on / decode / PiP-composition / subtitle / danmaku power costs from
each other) were added 2026-07-10. The tool's parsing functions have 56
offline unit tests (`tools/tests/test_monitor_piliplus_power.py`, no device
needed) and all pass. **The tool itself has never been run against a real
device in this round** — there is zero actual measurement data, and no
claim should be made anywhere that the PiP/power-saving changes have been
shown to reduce heat or battery drain. That still needs a human to run
`record`/`compare` on a Pixel 10 Pro per the guide.

## Build Environment Note (2026-07-10 round)

This round ran in an Anthropic-managed cloud Ubuntu session, not the user's
Windows machine referenced by earlier rounds' `D:\CodexTemp` paths. Flutter
3.44.5 (matching the repo's pinned version) was installed at
`/root/tooling/flutter` in that session and used for `pub get`/`format`/
`analyze`/`test`, all of which passed with zero new issues. However, this
session's outbound network policy blocks `dl.google.com` and
`android.googlesource.com` (confirmed via 403 policy-denial responses in
the egress proxy's own status log, not a timeout/cert issue) — those are
Android's only distribution channels for SDK platform-tools/build-tools/
NDK, so the Android SDK could not be installed and `flutter build apk`
failed at "No Android SDK found". **No APK was produced this round.** The
repo's `.github/workflows/build.yml` has a `workflow_dispatch`-triggered
`android` job that builds and uploads arm64/armv7/x86_64 release APKs as
workflow artifacts and is a more reliable path to an actual APK than a
sandboxed agent session — it was not triggered this round (running CI has
externally-visible side effects and needs explicit user go-ahead). Any
future agent attempting a from-scratch APK build in a similarly-locked-down
sandbox will hit the same wall; don't try to route around the blocked host,
just report it, same as this round did.

If run on a machine with real Android SDK access (the user's Windows
machine, or a CI runner with `dl.google.com` reachable), the build itself
is unchanged from what earlier rounds documented:

```
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
```

No key.properties/keystore exists in this repo or this session (it's
gitignored and never was checked in) — a build in any fresh environment
without the user's real keystore falls back to the Gradle debug signing
config (`android/app/build.gradle.kts`: `signingConfig = config ?:
signingConfigs["debug"]`), which will NOT overwrite an existing
release-signed install on the user's device.
