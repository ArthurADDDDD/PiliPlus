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

What remains: on-device validation (see TODO.md P0 checklist), especially
surface swap stability (quality switch / episode switch while in PiP will
re-attach output to the Flutter texture via media_kit onLoadHooks — the shell
window would freeze; acceptable for now, PipShell.hide handles page takeover).

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

## Local Temporary Dependencies

The temporary dependencies installed on this machine are outside the repository:

- `D:\CodexTemp\flutter_3.44.5_temp`
- `D:\CodexTemp\android_sdk_temp`
- `D:\CodexTemp\jdk17_temp`
- `D:\CodexTemp\gradle_user_home_temp`
- `D:\CodexTemp\pub_cache_temp`
- `D:\CodexTemp\flutter_appdata_temp`
- `D:\CodexTemp\flutter_localappdata_temp`

These are temporary local tools/caches and should not be committed.
