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
///
/// Surface 所有权真正的状态机在 [AndroidVideoController]
/// （attachExternalSurface / updateExternalSurfaceSize /
/// detachExternalSurfaceAndRestoreInternal / releaseExternalSurface）：
/// 分 P、清晰度切换、URL 重新加载等触发的 onUnloadHooks/onLoadHooks/
/// videoParams 都在那里正确处理"外部 surface 接管期间的重挂"，
/// 不再依赖本类缓存的旧 `_flutterWid` 作为恢复来源。
abstract final class PipShell {
  static bool active = false;

  static Map<dynamic, dynamic>? _routeArgs;

  /// PiP surface 的 wid（用于判断销毁事件是否针对当前输出）。
  static String? _pipWid;

  static PlPlayerController? get _ctr => PlPlayerController.instance;

  static AndroidVideoController? get _avc {
    final vc = _ctr?.videoController;
    return vc is AndroidVideoController ? vc : null;
  }

  /// 返回键路径入口：启动 PiP 壳。[routeArgs] 为重进 /videoV 的完整参数。
  static bool start(Map routeArgs) {
    if (!Platform.isAndroid) {
      return false;
    }
    final ctr = _ctr;
    final player = ctr?.videoPlayerController;
    if (ctr == null || player == null || _avc == null) {
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
    final avc = _avc;
    if (!active || avc == null) {
      PiliAndroidHelper.pipShellReleaseSurface();
      return;
    }
    _pipWid = wid;
    try {
      // AndroidVideoController 接管本次及之后每次媒体重载后的重挂，
      // 挂起时不再把输出抢回 Flutter 纹理（PiP 冻结的根因）。
      avc.attachExternalSurface(wid: wid, width: width, height: height);
      PiliAndroidHelper.pipShellLog('attached: target=$wid');
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
      _avc?.updateExternalSurfaceSize(width, height);
    } catch (_) {}
  }

  /// PiP surface 即将销毁：先把 mpv 输出摘掉，再让原生释放 Surface。
  static void onSurfaceDestroyed() {
    final player = _ctr?.videoPlayerController;
    final avc = _avc;
    try {
      // 展开流程可能已把输出切回 Flutter 纹理，别误伤
      if (player != null &&
          _pipWid != null &&
          player.getProperty('wid') == _pipWid) {
        player
          ..setOption('vo', 'null')
          ..setOption('wid', '0');
        avc?.releaseExternalSurface();
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
    _avc?.releaseExternalSurface();
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

  /// 展开/新页面接管时切回 Flutter 纹理；若内部 surface 尚未就绪
  /// （比如正处于媒体重载中途），退回 refreshPlayer() 让 media_kit 重建输出。
  static void _restoreFlutterSurface() {
    final ctr = _ctr;
    final avc = _avc;
    _pipWid = null;
    if (avc == null) {
      return;
    }
    try {
      final restored = avc.detachExternalSurfaceAndRestoreInternal();
      if (!restored) {
        ctr?.refreshPlayer();
      }
    } catch (e) {
      Utils.reportError(e);
    }
  }
}
