import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart' show AndroidHelper;
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/real.dart'
    show AndroidVideoController;

/// 系统原生 PiP 壳（返回键画中画）的 Dart 侧管理。
///
/// 原理：视频页 pop 后启动原生 `PipActivity`（Android 13+ 直接以 PiP 形态
/// 启动），把 libmpv 的输出 surface（`wid`）从 Flutter 纹理热切换到
/// PipActivity 的 TextureView；展开时切回 Flutter 纹理并无缝重进视频页。
/// PiP 窗口内为纯视频画面（弹幕由 Flutter 渲染，无法进入原生窗口）。
abstract final class PipShell {
  static bool active = false;

  static Map<dynamic, dynamic>? _routeArgs;

  /// Flutter 纹理的 wid（切走前保存，展开时恢复）。
  static String? _flutterWid;

  /// PiP surface 的 wid（用于判断销毁事件是否针对当前输出）。
  static String? _pipWid;

  /// 视频尺寸（恢复 Flutter 纹理时的 android-surface-size）。
  static int _videoWidth = 0;
  static int _videoHeight = 0;

  static PlPlayerController? get _ctr => PlPlayerController.instance;

  /// 返回键路径入口：启动 PiP 壳。[routeArgs] 为重进 /videoV 的完整参数。
  static bool start(Map routeArgs) {
    if (!Platform.isAndroid) {
      return false;
    }
    final ctr = _ctr;
    final player = ctr?.videoPlayerController;
    if (ctr == null || player == null || ctr.videoController == null) {
      return false;
    }

    final state = player.state;
    int width = state.width;
    int height = state.height;
    if (width <= 0 || height <= 0) {
      width = ctr.width ?? 16;
      height = ctr.height ?? 9;
    }
    if (width <= 0 || height <= 0) {
      return false;
    }
    _videoWidth = width;
    _videoHeight = height;

    try {
      _flutterWid = player.getProperty('wid');
    } catch (_) {
      _flutterWid = null;
    }

    _routeArgs = Map.of(routeArgs)
      ..remove('progress')
      ..remove('fromMiniPlayer');

    // 归一化宽高比，保护系统对 PiP 捏合大小的记忆
    (width, height) = PageUtils.normalizePipAspect(width, height);

    PiliAndroidHelper.enterPipShell(
      width: width,
      height: height,
      isLive: ctr.isLive,
      isPlaying: ctr.playerStatus.isPlaying,
    );
    active = true;
    return true;
  }

  /// PipActivity 的 TextureView surface 就绪：mpv 输出切换过去。
  static void onSurfaceCreated(String wid, int width, int height) {
    final player = _ctr?.videoPlayerController;
    if (!active || player == null) {
      PiliAndroidHelper.pipShellReleaseSurface();
      return;
    }
    _pipWid = wid;
    // 挂起 AndroidVideoController 的自动重挂，防止 videoParams 事件把
    // 输出抢回 Flutter 纹理（PiP 黑屏的根因）
    AndroidVideoController.externalSurfaceActive = true;
    try {
      // 与 media_kit 运行时重挂 surface 的顺序一致，不先置空 vo，
      // 减少 vo 销毁/重建带来的黑屏时间
      player
        ..setOption('android-surface-size', '${width}x$height')
        ..setOption('wid', wid)
        ..setOption('vo', 'gpu');
      PiliAndroidHelper.pipShellLog(
        'attached: target=$wid now=${player.getProperty('wid')} '
        'flutterWid=$_flutterWid vo=${player.getProperty('current-vo')}',
      );
    } catch (e) {
      PiliAndroidHelper.pipShellLog('attach failed: $e');
      Utils.reportError(e);
    }
  }

  /// PiP 窗口尺寸变化（原生缩放）。
  static void onSurfaceChanged(int width, int height) {
    if (!active) {
      return;
    }
    try {
      _ctr?.videoPlayerController?.setOption(
        'android-surface-size',
        '${width}x$height',
      );
    } catch (_) {}
  }

  /// PiP surface 即将销毁：先把 mpv 输出摘掉，再让原生释放 Surface。
  static void onSurfaceDestroyed() {
    final player = _ctr?.videoPlayerController;
    try {
      // 展开流程可能已把输出切回 Flutter 纹理，别误伤
      if (player != null &&
          _pipWid != null &&
          player.getProperty('wid') == _pipWid) {
        player
          ..setOption('vo', 'null')
          ..setOption('wid', '0');
      }
    } catch (_) {}
    _pipWid = null;
    PiliAndroidHelper.pipShellReleaseSurface();
  }

  /// 用户点了 PiP 展开：切回 Flutter 纹理并重进视频页。
  static void onExpanded() {
    if (!active) {
      return;
    }
    active = false;
    // 同步清 PiP 标志，避免重进的视频页按 PiP 布局构建（无详情/纯视频）
    AndroidHelper.isPipMode = false;
    _restoreFlutterSurface();
    final args = _routeArgs;
    _routeArgs = null;
    final cid = _ctr?.cid;
    if (args == null) {
      return;
    }
    Get.toNamed(
      '/videoV',
      arguments: {
        ...args,
        if (cid != null) 'heroTag': Utils.makeHeroTag(cid),
        'fromMiniPlayer': true,
      },
      preventDuplicates: false,
    );
  }

  /// PiP 被拖到关闭区域（或被系统回收）：停止并销毁播放器。
  static void onClosed() {
    if (!active) {
      return;
    }
    active = false;
    AndroidVideoController.externalSurfaceActive = false;
    _routeArgs = null;
    final ctr = _ctr;
    if (ctr == null) {
      return;
    }
    try {
      ctr.videoPlayerController
        // 同步 FFI 立即静音，dispose 的异步收尾不再影响听感
        ?..setOption('pause', 'yes')
        ..setOption('vo', 'null')
        ..setOption('wid', '0');
    } catch (_) {}
    _pipWid = null;
    try {
      ctr.makeHeartBeat(
        ctr.positionInMilliseconds ~/ 1000,
        type: HeartBeatType.completed,
        isManual: true,
      );
    } catch (_) {}
    ctr.dispose();
  }

  /// 新页面接管播放器（getInstance）时静默收起 PiP 壳。
  /// 新页面的 onLoadHooks 会自行重建 Flutter surface，无需在此恢复。
  static void hide() {
    if (!active) {
      return;
    }
    active = false;
    _routeArgs = null;
    // 同步清掉 PiP 标志：新视频页构建时会读它决定布局，
    // 等 PipActivity onDestroy 再清就晚了（页面会渲染成 PiP 纯视频布局）
    AndroidHelper.isPipMode = false;
    _restoreFlutterSurface();
    PiliAndroidHelper.pipShellFinish();
  }

  static void _restoreFlutterSurface() {
    AndroidVideoController.externalSurfaceActive = false;
    final ctr = _ctr;
    final player = ctr?.videoPlayerController;
    if (player == null) {
      return;
    }
    final wid = _flutterWid;
    _pipWid = null;
    try {
      player.setOption('vo', 'null');
      if (wid != null && wid.isNotEmpty && wid != '0') {
        if (_videoWidth > 0 && _videoHeight > 0) {
          player.setOption(
            'android-surface-size',
            '${_videoWidth}x$_videoHeight',
          );
        }
        player
          ..setOption('wid', wid)
          ..setOption('vo', 'gpu');
      } else {
        // 兜底：拿不到原 wid 时，以当前进度重开让 media_kit 重建输出
        ctr!.refreshPlayer();
      }
    } catch (e) {
      Utils.reportError(e);
    }
  }
}
