import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/pages/danmaku/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart' show AndroidHelper;
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 应用内小窗播放器：返回键离开视频页后，播放器以浮动小窗
/// 继续渲染在任意页面之上（同一 FlutterEngine，直接复用现有纹理）。
abstract final class MiniVideoPlayer {
  static OverlayEntry? _entry;
  static Map<dynamic, dynamic>? _routeArgs;

  /// Android 系统 PiP 进行中：小窗切换为全屏纯视频渲染，
  /// 避免系统 PiP 画面里出现缩小的普通页面。
  static final ValueNotifier<bool> systemPipMode = ValueNotifier(false);

  static bool get active => _entry != null;

  /// [routeArgs] 需为重进 /videoV 可用的完整参数（cid 等取当前播放值）。
  static bool show(Map routeArgs) {
    if (!Platform.isAndroid) {
      return false;
    }
    final ctr = PlPlayerController.instance;
    final overlay = Get.key.currentState?.overlay;
    if (ctr == null || ctr.videoController == null || overlay == null) {
      return false;
    }
    hide();
    _routeArgs = Map.of(routeArgs)
      ..remove('progress')
      ..remove('fromMiniPlayer');
    PiliAndroidHelper.onPictureInPictureModeChanged = _onSystemPipChanged;
    _entry = OverlayEntry(
      builder: (context) => _MiniPlayerWidget(controller: ctr),
    );
    overlay.insert(_entry!);
    return true;
  }

  static void _onSystemPipChanged(bool isInPip) {
    systemPipMode.value = isInPip;
  }

  /// 仅移除浮层，不干预播放（供展开/新视频页接管时使用）。
  static void hide() {
    final entry = _entry;
    if (entry == null) {
      return;
    }
    _entry = null;
    // 可能在页面 build 期间被调用（getInstance），避免 build 中触发重建
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => entry.remove());
    } else {
      entry.remove();
    }
    systemPipMode.value = false;
    if (PiliAndroidHelper.onPictureInPictureModeChanged ==
        _onSystemPipChanged) {
      PiliAndroidHelper.onPictureInPictureModeChanged = null;
    }
  }

  /// 展开回视频页，衔接当前播放实例。
  static void expand() {
    final args = _routeArgs;
    final cid = PlPlayerController.instance?.cid;
    hide();
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

  /// 关闭小窗：上报进度并销毁播放器。
  static void close() {
    hide();
    _routeArgs = null;
    final ctr = PlPlayerController.instance;
    if (ctr == null) {
      return;
    }
    try {
      ctr.makeHeartBeat(
        ctr.positionInMilliseconds ~/ 1000,
        type: HeartBeatType.completed,
        isManual: true,
      );
    } catch (_) {}
    ctr.dispose();
  }
}

class _MiniPlayerWidget extends StatefulWidget {
  const _MiniPlayerWidget({required this.controller});

  final PlPlayerController controller;

  @override
  State<_MiniPlayerWidget> createState() => _MiniPlayerWidgetState();
}

class _MiniPlayerWidgetState extends State<_MiniPlayerWidget>
    with WidgetsBindingObserver {
  PlPlayerController get ctr => widget.controller;

  Offset? _pos;
  bool _dragging = false;
  bool _showControls = false;
  Timer? _hideTimer;
  bool _pausedByBackground = false;

  static const double _margin = 12;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // 页面级播放器不在时，由小窗承接后台暂停策略
  // （与 PLVideoPlayer 的 _pauseAfterPipSettles 行为一致）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (ctr.continuePlayInBackground.value) {
      return;
    }
    if (const <AppLifecycleState>[.paused, .detached].contains(state)) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        final lifecycleState = WidgetsBinding.instance.lifecycleState;
        final isBackground = const <AppLifecycleState>[
          .paused,
          .detached,
        ].contains(lifecycleState);
        if (!mounted || !isBackground || AndroidHelper.isPipMode) {
          return;
        }
        final player = ctr.videoPlayerController;
        if (player != null && player.state.playing) {
          _pausedByBackground = true;
          player.pause();
        }
      });
    } else if (state == AppLifecycleState.resumed && _pausedByBackground) {
      _pausedByBackground = false;
      ctr.videoPlayerController?.play();
    }
  }

  double get _aspectRatio {
    final state = ctr.videoPlayerController?.state;
    final w = (state?.width ?? 0) > 0 ? state!.width : ctr.width;
    final h = (state?.height ?? 0) > 0 ? state!.height : ctr.height;
    if (w != null && h != null && w > 0 && h > 0) {
      return w / h;
    }
    return 16 / 9;
  }

  Size _windowSize(Size screen, double aspectRatio) {
    double width;
    if (aspectRatio < 1) {
      width = (screen.width * 0.36).clamp(140.0, 220.0);
    } else {
      width = (screen.width * 0.55).clamp(200.0, 336.0);
    }
    return Size(width, width / aspectRatio);
  }

  Offset _clampPos(Offset pos, Size screen, Size size, EdgeInsets padding) {
    return Offset(
      pos.dx.clamp(
        padding.left + _margin,
        screen.width - size.width - padding.right - _margin,
      ),
      pos.dy.clamp(
        padding.top + _margin,
        screen.height - size.height - padding.bottom - _margin,
      ),
    );
  }

  void _toggleControls([bool? show]) {
    _hideTimer?.cancel();
    setState(() => _showControls = show ?? !_showControls);
    if (_showControls) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => _showControls = false);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    super.dispose();
  }

  Widget _video(double aspectRatio) => SimpleVideo(
    controller: ctr.videoController!,
    aspectRatio: aspectRatio,
  );

  Widget? _danmaku(Size size) {
    final cid = ctr.cid;
    if (Pref.pipNoDanmaku || cid == null) {
      return null;
    }
    return IgnorePointer(
      child: PlDanmaku(
        key: ValueKey('mini$cid${size.width.round()}'),
        cid: cid,
        playerController: ctr,
        isPipMode: true,
        isFullScreen: false,
        isFileSource: ctr.isFileSource,
        size: size,
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 28,
  }) => IconButton(
    onPressed: onTap,
    icon: Icon(icon, size: size, color: Colors.white),
    style: IconButton.styleFrom(
      backgroundColor: Colors.black.withValues(alpha: 0.35),
      padding: const EdgeInsets.all(6),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  Widget _controls() => Positioned.fill(
    child: ColoredBox(
      color: Colors.black38,
      child: Stack(
        children: [
          Positioned(
            top: 4,
            left: 4,
            child: _controlButton(
              icon: Icons.open_in_full,
              size: 20,
              onTap: MiniVideoPlayer.expand,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: _controlButton(
              icon: Icons.close,
              size: 20,
              onTap: MiniVideoPlayer.close,
            ),
          ),
          Center(
            child: Obx(
              () => _controlButton(
                icon: ctr.playerStatus.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 36,
                onTap: () {
                  if (ctr.playerStatus.isPlaying) {
                    ctr.pause();
                  } else {
                    ctr.play();
                  }
                  _toggleControls(true);
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MiniVideoPlayer.systemPipMode,
      builder: (context, inSystemPip, _) {
        if (ctr.videoController == null) {
          return const SizedBox.shrink();
        }
        final aspectRatio = _aspectRatio;
        if (inSystemPip) {
          final screen = MediaQuery.sizeOf(context);
          return Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _video(aspectRatio),
                  ?_danmaku(screen),
                ],
              ),
            ),
          );
        }

        final mq = MediaQuery.of(context);
        final screen = mq.size;
        final size = _windowSize(screen, aspectRatio);
        final pos = _clampPos(
          _pos ??
              Offset(
                screen.width - size.width - mq.padding.right - _margin,
                screen.height - size.height - mq.padding.bottom - _margin - 68,
              ),
          screen,
          size,
          mq.padding,
        );

        return AnimatedPositioned(
          duration: _dragging ? Duration.zero : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          left: pos.dx,
          top: pos.dy,
          width: size.width,
          height: size.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (details) {
              setState(() => _pos = pos + details.delta);
            },
            onPanEnd: (_) {
              // 吸附到左右屏幕边缘
              final centerX = pos.dx + size.width / 2;
              final snapX = centerX < screen.width / 2
                  ? mq.padding.left + _margin
                  : screen.width - size.width - mq.padding.right - _margin;
              setState(() {
                _dragging = false;
                _pos = Offset(snapX, pos.dy);
              });
            },
            child: Material(
              color: Colors.black,
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _video(aspectRatio),
                  ?_danmaku(size),
                  if (_showControls) _controls(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
