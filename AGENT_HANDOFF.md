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

### 5b. PiP paused-then-dismissed resumes playback (small fix, needs on-device validation)

User-reported (2026-07-10, mid-session): pausing a video while in native PiP
and then dragging PiP to the dismiss target caused it to resume playing in
the background; dragging to dismiss while actively playing correctly paused
it. Root cause (best static-analysis guess, not confirmed via logcat):
`PipShell._restoreFlutterSurface()`'s fallback path (used when the internal
Flutter surface isn't ready yet) called `PlPlayerController.refreshPlayer()`,
which unconditionally reopened the media with `play: true` -- if a PiP
expand/close misdetection race fires this fallback for what was actually a
dismiss (not an expand) of an already-paused player, it silently resumes
playback with no visible video page to notice it on. Fixed:
`refreshPlayer()` now takes an optional `play` parameter (default `true`,
preserving its other call site's behavior -- a live-stream/URL reconnect
retry, where forcing playback is correct); `PipShell` now passes
`play: ctr.playerStatus.isPlaying` instead of relying on the default. Not
validated on a device. If this turns out not to fully fix it, the next
place to look is the actual expand-vs-close detection timing in
`PipActivity.kt` (`onPictureInPictureModeChanged`/`onStop`), which this
round didn't change.

### 6. Self-update + GitHub Release publishing (code finished, needs first real release + on-device validation)

2026-07-10 follow-up round: built a full self-update/release pipeline for
this fork, entirely code + CI configuration, **nothing was actually
published or run** (no GitHub Actions execution, no tag, no Release, no
device testing -- all explicitly out of scope per the task).

- `lib/utils/update/release_update_logic.dart`: pure version/tag parsing
  (`ReleaseVersion`, `<name>+<buildNumber>` form), GitHub `releases/latest`
  response classification (`LatestReleaseFound`/`NotFound`/`Error`, with
  draft/prerelease filtering), the actual "should we prompt" decision
  (`decideShouldPromptUpdate` -- build-number comparison as primary signal,
  timestamp comparison as an explicitly-labeled fallback only when the tag
  doesn't parse), and Android ABI-to-APK-asset matching
  (`pickAndroidApkAsset`). 46 offline unit tests in
  `test/utils/update/release_update_logic_test.dart`, all passing, covering
  every scenario the task spec called out.
- `lib/utils/update.dart` rewritten as the thin impure layer: hits
  `Api.latestRelease` (now `GET /repos/ArthurADDDDD/PiliPlus/releases/latest`,
  owner/repo centralized in `Constants.githubOwner`/`githubRepo`), classifies
  the response, decides, and drives an expanded update dialog (tag, name,
  body, published date, current vs. new version, download/view-release/
  cancel buttons, "don't remind me again" preserved for the auto-check path).
- `.github/workflows/build.yml` android job restructured into three
  distinct paths: PR (compile verification only, this fork's own PRs now
  allowed to trigger it, never touches release secrets), workflow_dispatch
  with an empty tag (test build: `.dev` applicationId, debug/dev signing,
  Actions-artifact-only, never becomes a Release), and workflow_dispatch
  with a non-empty tag (formal release: fails closed if
  `SIGN_KEYSTORE_BASE64`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD` are
  missing, if the tag doesn't exactly match `pubspec.yaml`'s
  `<versionName>+<buildNumber>` -- validated by the new
  `lib/scripts/release_version.ps1`, which deliberately does NOT reuse
  `build.ps1`'s `git rev-list --count HEAD`-derived build number for
  releases, to avoid two conflicting version sources -- or if the tag
  already exists as a release). Formal releases get an `apksigner verify`
  gate, a `SHA256SUMS.txt`, a job summary with commit/version/signing-type/
  APK hashes (no secrets), and are created with `target_commitish:
  github.sha`, `generate_release_notes: true`, non-draft, non-prerelease.
  `workflow_dispatch` defaults now only auto-check `build_android`.
- `docs/RELEASE_GUIDE.md` (Chinese, written for a non-CI-expert maintainer):
  one-time release-keystore generation and GitHub Secrets setup, old-APK
  signature-compatibility caveats (can't override-install across different
  signing certs, `adb install -r -d` doesn't bypass this, losing the
  keystore means future releases can't override-install), the exact formal
  release steps, and the test-build vs. formal-release distinction.
- `.gitignore` gained `**/android/app/key.jks` and `*.keystore` (existing
  `**/android/key.properties` and `*.jks` were already there); verified
  nothing matching any of these patterns is currently tracked.
- `test/` (the main app's root test directory, not just
  `third_party/media_kit_video/test/`) had to be un-ignored: the repo's
  `.gitignore` had an upstream-inherited `test*` rule that blocked ANY
  root-level `test/` directory. Narrowed to `/test*` plus an explicit
  `!/test/` negation so the standard Flutter test directory is trackable
  again without dropping whatever the original rule was protecting against.

**2026-07-10 second follow-up round: existing-key reuse + certificate
fingerprint pinning.** The user did their own local audit and found the
APK currently installed on their device is signed by a certificate
(SHA-256 `2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349`)
matching a keystore still on their machine
(`C:\Users\...\.android\debug.keystore`, alias `androiddebugkey`). The
earlier round's guidance implicitly pushed toward "generate a brand-new
release keystore," which would have forced an unnecessary uninstall/data
loss. Corrected: Android's override-install check only cares about
`applicationId` + certificate match, not what the keystore file is named
or whether it's nominally a "debug" key -- reusing that exact keystore as
the permanent signing key (Plan A in `docs/RELEASE_GUIDE.md` section 1,
now the recommended path) avoids the uninstall entirely, at the accepted
cost that a "debug" keystore's password strength is typically weaker
(explicitly documented, not hidden).

To guard against a *different* valid keystore being mistakenly configured
later (e.g. swapping in Plan B's keystore while believing it's still Plan
A's), added a certificate-fingerprint pinning layer:

- `lib/scripts/signing_fingerprint.ps1`: dot-sourceable, dependency-free
  (no Pester) PowerShell library with pure functions
  (`ConvertTo-NormalizedFingerprint`, `Test-FingerprintMatch`,
  `ConvertFrom-KeytoolCertOutput`, `ConvertFrom-ApksignerCertOutput`) and
  thin impure wrappers that shell out to `keytool`/`apksigner`
  (`Get-KeystoreCertFingerprint`, `Get-ApkCertFingerprint`).
  `lib/scripts/signing_fingerprint.tests.ps1` exercises the pure functions
  offline with hand-built keytool/apksigner-shaped text -- **could not be
  executed in this sandbox** (no `pwsh` available, same limitation as the
  earlier `release_version.ps1` round), verified only by careful manual
  read-through; needs a real `pwsh` run before being trusted.
- `.github/workflows/build.yml`'s release path now reads a new
  **Repository Variable** (not a Secret -- fingerprints aren't sensitive)
  `EXPECTED_SIGNING_CERT_SHA256`, validates its format before doing
  anything else, re-derives the actual keystore's certificate fingerprint
  right after decoding it (before the Flutter build even starts) and
  fails closed on any mismatch, then re-derives each built APK's actual
  certificate fingerprint via `apksigner` after the build and fails closed
  again if either the keystore-stage or APK-stage fingerprint doesn't
  match. All three values (expected/keystore/APK) plus applicationId are
  written to the job summary, never a password/Base64/private key.
- `docs/RELEASE_GUIDE.md` restructured: section 1 now explicitly offers
  Plan A (reuse existing signing, recommended for this user) vs. Plan B
  (new dedicated key, forces one uninstall), with the risk tradeoffs of
  Plan A spelled out; new backup/confirm/base64/secrets/variable
  sub-steps mirroring the user's actual Windows workflow; new section 5
  ("版本兼容说明") stating the currently-audited installed APK's
  `versionCode: 1` and why any real release's build number trivially
  clears that bar.

**What's actually still needed, none of which this round did:**

- Configure the 4 GitHub Actions secrets **and** the
  `EXPECTED_SIGNING_CERT_SHA256` Repository Variable on
  `ArthurADDDDD/PiliPlus`.
- Bump `pubspec.yaml`'s `version:` (currently the placeholder `2.0.9+1`) to
  a real `<name>+<buildNumber>` and commit it to `main`.
- Manually trigger the workflow with a matching tag to produce the fork's
  **first-ever** GitHub Release (confirmed via the GitHub API in the prior
  round: zero releases exist today; not re-checked this round per the
  "don't trigger anything" constraint).
- Verify on an actual device with the currently-installed build: the
  update dialog appears, its content is correct, "download update" opens
  the right arm64-v8a asset, and the install genuinely **overrides**
  (does not prompt about a signature conflict, does not require an
  uninstall, local data survives).
- Manually confirm each of the four failure-closed preflight paths
  (mismatched tag, missing secrets, duplicate tag, certificate fingerprint
  mismatch) actually fails the workflow in practice, not just on paper.
- Publish a second release with a higher build number and confirm the
  first release's install actually receives and can act on the update
  prompt (validates the full loop, not just the first install).
- Run `lib/scripts/signing_fingerprint.tests.ps1` somewhere with real
  `pwsh` -- it was written and manually reviewed but never executed.

Do not claim self-update, override-install, or the fingerprint pinning
has been validated end-to-end until the above is done by a human with
real GitHub Actions access and a real device.

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
