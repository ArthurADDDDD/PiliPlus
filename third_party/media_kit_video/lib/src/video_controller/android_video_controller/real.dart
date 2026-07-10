/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

// ignore_for_file: implementation_imports
import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit_video/src/video_controller/android_video_controller/external_surface_ownership.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template android_video_controller}
///
/// AndroidVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native JNI & C/C++ used on Android.
///
/// {@endtemplate}
class AndroidVideoController extends PlatformVideoController {
  /// Whether [AndroidVideoController] is supported on the current platform or not.
  static bool get supported => Platform.isAndroid;

  // ---------------------------------------------------------------------
  // PiliPlus patch: external (native) surface ownership.
  //
  // When a native PiP shell (or any other native surface consumer) takes
  // over the libmpv video output, [attachExternalSurface] hands ownership
  // to it. While active, media reloads (quality/episode switch, URL
  // reload, ...) must keep re-attaching the *external* surface instead of
  // silently stealing the output back to the internal Flutter texture --
  // that silent steal was the root cause of PiP freezing on reload.
  //
  // `onUnloadHooks` always tears down `vo=null`/`wid=0` because libmpv
  // requires it. If external ownership is active at that point, [_external]
  // marks itself pending re-attachment so the very next `onLoadHooks` /
  // `videoParams` event re-attaches the external surface (with its last
  // known size) instead of the internal one. [_loadGeneration] guards the
  // async `CreateSurface` gap so a superseded/disposed load can't clobber
  // state set by a newer one. Both are implemented as small,
  // dependency-free classes (see external_surface_ownership.dart) so the
  // ownership bookkeeping can be unit tested offline.
  // ---------------------------------------------------------------------

  final _external = ExternalSurfaceOwnership();
  final _loadGeneration = LoadGeneration();

  int _lastVideoWidth = 0;
  int _lastVideoHeight = 0;

  /// Whether the video output is currently owned by an external (e.g.
  /// native PiP shell) surface rather than the internal Flutter texture.
  bool get isExternalSurfaceActive => _external.active;

  /// Hand libmpv's video output over to an externally-owned Android
  /// Surface (identified by its JNI global-ref [wid], as a decimal
  /// string). Suspends the internal Flutter surface's auto-reattach until
  /// [detachExternalSurfaceAndRestoreInternal] or [releaseExternalSurface]
  /// is called. Safe to call again (e.g. after a reload) to re-assert
  /// ownership.
  void attachExternalSurface({
    required String wid,
    required int width,
    required int height,
  }) {
    _external.attach(wid, width, height);
    _applyExternalSurfaceLocked();
  }

  /// Update the size of the currently-attached external surface (e.g. the
  /// native PiP window was resized). No-op if no external surface is
  /// attached, or if a reload is currently pending re-attachment (the
  /// pending re-attach will pick up the latest size on its own).
  void updateExternalSurfaceSize(int width, int height) {
    if (!_external.updateSize(width, height)) {
      return;
    }
    try {
      player.setOption('android-surface-size', '${width}x$height');
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
    }
  }

  /// Give ownership of the output back to the internal Flutter surface,
  /// restoring it using the *current* internal `wid` (never a stale
  /// reference cached before the external takeover) and the most recently
  /// known video size. Returns `false` if the internal surface isn't
  /// ready yet (e.g. a reload is still in flight) and the caller should
  /// fall back to e.g. refreshing the player; returns `true` if either
  /// the restore succeeded or an in-flight reload will complete it.
  bool detachExternalSurfaceAndRestoreInternal() {
    final reloadInFlight = _external.detach();
    if (reloadInFlight) {
      // A media reload is mid-flight; onLoadHooks/videoParams will attach
      // the fresh internal surface itself now that ownership is internal
      // again. Racing it here with a possibly-stale `_wid` would just
      // cause an extra flicker.
      return true;
    }
    if (_wid == null) {
      return false;
    }
    try {
      player.setOption('vo', 'null');
      if (_lastVideoWidth > 0 && _lastVideoHeight > 0) {
        player.setOption(
          'android-surface-size',
          '${_lastVideoWidth}x$_lastVideoHeight',
        );
      }
      player.setOption('wid', _wid.toString());
      player.setOption('vo', vo);
      return true;
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
      return false;
    }
  }

  /// Clear external surface ownership without touching the player's
  /// vo/wid options -- used when the external surface itself is being
  /// destroyed (caller is responsible for tearing down vo/wid first if
  /// still pointed at it) or the player is about to be disposed.
  void releaseExternalSurface() {
    _external.release();
  }

  void _applyExternalSurfaceLocked() {
    final wid = _external.wid;
    if (!_external.active || wid == null) {
      return;
    }
    try {
      final width = _external.width;
      final height = _external.height;
      if (width > 0 && height > 0) {
        player.setOption('android-surface-size', '${width}x$height');
      }
      player.setOption('wid', wid);
      player.setOption('vo', vo);
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
    }
  }

  // ---------------------------------------------------------------------

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  // ----------------------------------------------

  bool get androidAttachSurfaceAfterVideoParameters =>
      configuration.androidAttachSurfaceAfterVideoParameters ?? vo == 'gpu';

  /// --vo
  String get vo => configuration.vo ?? 'gpu';

  /// --hwdec
  // Future<String> get hwdec async {
  //   if (_hwdec != null) {
  //     return _hwdec!;
  //   }
  //   bool enableHardwareAcceleration = configuration.enableHardwareAcceleration;
  //   // Enforce software rendering in emulators.
  //   final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
  //   if (isEmulator) {
  //     debugPrint('media_kit: AndroidVideoController: Emulator detected.');
  //     debugPrint('media_kit: AndroidVideoController: Enforcing S/W rendering.');
  //     enableHardwareAcceleration = false;
  //   }
  //   _hwdec =
  //       configuration.hwdec ??
  //       (enableHardwareAcceleration ? 'auto-safe' : 'no');
  //   return _hwdec!;
  // }

  // ----------------------------------------------

  String? _current;

  /// {@macro android_video_controller}
  AndroidVideoController._(super.player, super.configuration) {
    player.onLoadHooks.add(() {
      return _lock.synchronized(() async {
        if (_loadGeneration.isDisposed) {
          return;
        }
        final mpv = NativePlayer.mpv;
        final ctx = player.ctx;

        // Skip surface re-creation if same resource.
        final name = 'path'.toNativeUtf8();
        final path = mpv.mpv_get_property_string(ctx, name);
        final current = path.toDartString();
        calloc.free(name.cast());
        mpv.mpv_free(path.cast());

        if (_current != current) {
          _current = current;
          // It is important to use a new android.view.Surface each time a new video-output is created because: https://stackoverflow.com/a/21564236
          // Not doing so will cause MediaCodec usage inside libavcodec to incorrectly fail with error (because this android.view.Surface would be used twice):
          // "native_window_api_connect returned an error: Invalid argument (-22)" & next less-efficient hwdec will be used redundantly.

          // Create a new android.view.Surface & obtain object reference to it.
          // NOTE: Previous android.view.Surface & object reference is internally released/destroyed by the method.
          final generation = _loadGeneration.next();
          final data = await _channel.invokeMethod(
            'VideoOutputManager.CreateSurface',
            {'handle': ctx.address.toString()},
          );
          debugPrint(data.toString());
          if (!_loadGeneration.isCurrent(generation)) {
            // A newer load (or dispose) superseded this one while awaiting
            // the platform channel; the surface it created is stale, drop it.
            return;
          }
          // Save the android.view.Surface object reference for usage inside player.stream.videoParams.listen.
          _wid = data['wid'];
        }

        // By default, android.view.Surface has a size of 1x1. If we assign --wid here, libmpv will internally start rendering & the first frame will be drawn as a solid color: https://github.com/media-kit/media-kit/issues/339
        // The solution is to assign --wid after android.graphics.SurfaceTexture.setDefaultBufferSize has been called & --android-surface-size has been updated (see inside player.stream.videoParams.listen).

        // Assign --wid here if --vo is not "gpu" or "null" i.e. custom vo/hwdec was passed through [VideoControllerConfiguration].
        try {
          // ----------------------------------------------
          if (_external.consumeReattachIfNeeded()) {
            // PiliPlus patch: an external (e.g. native PiP) surface owns the
            // output; reattach *it* now that a fresh media/surface is
            // loaded instead of stealing the output back to the Flutter
            // texture (this used to freeze the PiP window on reload).
            _applyExternalSurfaceLocked();
          } else if (!androidAttachSurfaceAfterVideoParameters) {
            player.setOption('wid', _wid.toString());
            player.setOption('vo', vo);
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });
    player.onUnloadHooks.add(() {
      return _lock.synchronizedSync(() {
        // Release any references to current android.view.Surface.
        //
        // It is important to set --vo=null here for 2 reasons:
        // 1. Allow the native code to drop any references to the android.view.Surface.
        // 2. Resize the android.graphics.SurfaceTexture to next video's resolution before setting --vo=gpu.
        try {
          // ----------------------------------------------
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
        // PiliPlus patch: if an external surface owns the output, libmpv
        // just needs vo/wid torn down across the reload -- mark it so the
        // upcoming onLoadHooks/videoParams re-attaches the external
        // surface instead of leaving the output nowhere (frozen last
        // frame) or stealing it back to the internal Flutter surface.
        _external.onUnload();
      });
    });

    _subscription = player.stream.videoParams.listen(
      (event) => _lock.synchronized(() async {
        if (_loadGeneration.isDisposed) {
          return;
        }
        if (const [0, null].contains(event.dw) ||
            const [0, null].contains(event.dh) ||
            _wid == null) {
          return;
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }
        _lastVideoWidth = width;
        _lastVideoHeight = height;

        if (_external.active) {
          // PiliPlus patch: output belongs to the external (e.g. PiP)
          // surface. Still keep the internal Flutter SurfaceTexture sized
          // correctly (so a later expand-time restore doesn't hand mpv an
          // undersized/stale internal surface), but never re-point the
          // actual output (`wid`/`vo`) at it while external ownership
          // holds.
          try {
            await _channel
                .invokeMethod('VideoOutputManager.SetSurfaceTextureSize', {
                  'handle': player.handle.toString(),
                  'width': width.toString(),
                  'height': height.toString(),
                });
          } catch (exception, stacktrace) {
            debugPrint(exception.toString());
            debugPrint(stacktrace.toString());
          }
          if (_loadGeneration.isDisposed) {
            return;
          }
          if (_external.consumeReattachIfNeeded()) {
            _applyExternalSurfaceLocked();
          } else {
            try {
              player.setOption('android-surface-size', '${width}x$height');
            } catch (exception, stacktrace) {
              debugPrint(exception.toString());
              debugPrint(stacktrace.toString());
            }
          }
          rect.value = Rect.fromLTRB(
            0.0,
            0.0,
            width.toDouble(),
            height.toDouble(),
          );
          return;
        }

        rect.value = Rect.zero;
        try {
          if (vo == 'gpu') {
            // NOTE: Only required for --vo=gpu
            // With --vo=gpu, we need to update the android.graphics.SurfaceTexture size & notify libmpv to re-create vo.
            // In native Android, this kind of rendering is done with android.view.SurfaceView + android.view.SurfaceHolder, which offers onSurfaceChanged to handle this.
            await _channel
                .invokeMethod('VideoOutputManager.SetSurfaceTextureSize', {
                  'handle': player.handle.toString(),
                  'width': width.toString(),
                  'height': height.toString(),
                });

            // ----------------------------------------------
            if (_loadGeneration.isDisposed || _external.active) {
              // Superseded by a dispose or an external takeover while we
              // were awaiting the platform channel above; don't clobber it.
              return;
            }
            player.setOption('android-surface-size', '${width}x$height');
            player.setOption('wid', _wid.toString());
            player.setOption('vo', 'gpu');
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
        rect.value = Rect.fromLTRB(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );
      }),
    );
  }

  /// {@macro android_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = AndroidVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    final data = await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
    });
    debugPrint(data.toString());

    final int? id = data['id'];

    // ----------------------------------------------

    final values = {
      // It is necessary to set vo=null here to avoid SIGSEGV, --wid must be assigned before vo=gpu is set.
      'vo': 'null',
      'hwdec':
          configuration.hwdec ??
          (configuration.enableHardwareAcceleration ? 'auto-safe' : 'no'),
      'vid': 'auto',
      'opengl-es': 'yes',
      'force-window': 'yes',
      'gpu-context': 'android',
      'sub-use-margins': 'no',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    };

    for (final entry in values.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      NativePlayer.mpv.mpv_set_property_string(player.ctx, name, value);
      calloc.free(name);
      calloc.free(value);
    }
    // ----------------------------------------------

    controller.id.value = id;

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void>? setSize({int? width, int? height}) {
    throw UnsupportedError(
      '[AndroidVideoController.setSize] is not available on Android',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    // PiliPlus patch: mark disposed so any in-flight onLoadHooks/videoParams
    // callback awaiting a platform channel result recognizes itself as
    // stale and no-ops instead of touching a disposed player.
    _loadGeneration.dispose();
    releaseExternalSurface();
    // Dispose the [StreamSubscription]s.
    await _subscription?.cancel();
    // Release the native resources.
    final handle = player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  int? _wid;

  /// [Lock] used to synchronize the [_widthStreamSubscription] & [_heightStreamSubscription].
  final _lock = Lock();

  /// [StreamSubscription] for listening to video [Rect] from [_controller].
  StreamSubscription<VideoParams>? _subscription;

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel(
        'com.alexmercerind/media_kit_video',
      )..setMethodCallHandler((MethodCall call) async {
        try {
          debugPrint(call.method.toString());
          debugPrint(call.arguments.toString());
          switch (call.method) {
            case 'VideoOutput.WaitUntilFirstFrameRenderedNotify':
              {
                // Notify about updated texture ID & [Rect].
                final int handle = call.arguments['handle'];
                debugPrint(handle.toString());
                // Notify about the first frame being rendered.
                final completer =
                    _controllers[handle]?.waitUntilFirstFrameRenderedCompleter;
                if (!(completer?.isCompleted ?? true)) {
                  completer?.complete();
                }
                break;
              }
            default:
              {
                break;
              }
          }
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
}
