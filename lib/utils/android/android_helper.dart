import 'dart:convert';
import 'dart:ui';

import 'package:PiliPlus/plugin/pl_player/pip_shell.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/services.dart';
import 'package:jni/jni.dart';

abstract final class PiliAndroidHelper {
  static const MethodChannel _channel = MethodChannel('piliplus/android');
  static bool _methodChannelInitialized = false;
  static void Function(bool isInPictureInPictureMode)?
  onPictureInPictureModeChanged;

  static void ensureMethodChannel() {
    if (_methodChannelInitialized) {
      return;
    }
    _methodChannelInitialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPictureInPictureModeChanged':
          onPictureInPictureModeChanged?.call(call.arguments == true);
        case 'PipShell.surfaceCreated':
          final args = call.arguments as Map;
          PipShell.onSurfaceCreated(
            args['wid'] as String,
            args['width'] as int,
            args['height'] as int,
          );
        case 'PipShell.surfaceChanged':
          final args = call.arguments as Map;
          PipShell.onSurfaceChanged(
            args['width'] as int,
            args['height'] as int,
          );
        case 'PipShell.surfaceDestroyed':
          PipShell.onSurfaceDestroyed();
        case 'PipShell.expanded':
          PipShell.onExpanded();
        case 'PipShell.closed':
          PipShell.onClosed();
      }
    });
  }

  static Future<void> enterPipShell({
    required int width,
    required int height,
    required bool isLive,
    required bool isPlaying,
  }) async {
    try {
      await _channel.invokeMethod('enterPipShell', {
        'width': width,
        'height': height,
        'isLive': isLive,
        'isPlaying': isPlaying,
      });
    } catch (e) {
      Utils.reportError(e);
    }
  }

  static Future<void> pipShellReleaseSurface() async {
    try {
      await _channel.invokeMethod('pipShellReleaseSurface');
    } catch (_) {}
  }

  static Future<void> pipShellFinish() async {
    try {
      await _channel.invokeMethod('pipShellFinish');
    } catch (_) {}
  }

  static void pipShellLog(String message) {
    try {
      _channel.invokeMethod('pipShellLog', message);
    } catch (_) {}
  }

  static Future<void> setPowerSaveRefreshRate(bool enabled) async {
    try {
      await _channel.invokeMethod('setPowerSaveRefreshRate', enabled);
    } catch (_) {}
  }

  static Future<void> setPauseOnPipDismiss(bool enabled) async {
    try {
      await _channel.invokeMethod('setPauseOnPipDismiss', enabled);
    } catch (_) {}
  }

  /// 切换应用图标：true=国际版 bilibili，false=原版 PiliPlus。
  static Future<void> setAppIcon(bool bilibili) async {
    try {
      await _channel.invokeMethod('setAppIcon', bilibili);
    } catch (_) {}
  }

  @pragma('vm:prefer-inline')
  static void back() => AndroidHelper.back();

  static void biliSendCommAntifraud(
    int action,
    int oid,
    int type,
    int rpId,
    int root,
    int parent,
    int ctime,
    String commentText,
    List pictures,
    String sourceId,
    int uid,
    String cookie,
  ) {
    final jCommentText = commentText.toJString();
    final jSourceId = sourceId.toJString();
    final jCookie = cookie.toJString();
    final jPictures = pictures.isEmpty
        ? null
        : jsonEncode(pictures).toJString();

    try {
      AndroidHelper.biliSendCommAntifraud(
        action,
        oid,
        type,
        rpId,
        root,
        parent,
        ctime,
        jCommentText,
        jPictures,
        jSourceId,
        uid,
        jCookie,
      );
    } catch (e) {
      Utils.reportError(e);
    } finally {
      jCommentText.release();
      jSourceId.release();
      jCookie.release();
      jPictures?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void openLinkVerifySettings() =>
      AndroidHelper.openLinkVerifySettings();

  static bool openMusic(String title, String? artist, String? album) {
    final jTitle = title.toJString();
    final jArtist = artist?.toJString();
    final jAlbum = album?.toJString();
    try {
      return AndroidHelper.openMusic(jTitle, jArtist, jAlbum);
    } finally {
      jTitle.release();
      jArtist?.release();
      jAlbum?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void enterPip(
    int width,
    int height, {
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
  }) => AndroidHelper.enterPip(
    PlatformDispatcher.instance.engineId!,
    width,
    height,
    autoEnter,
    isLive,
    isPlaying,
  );

  @pragma('vm:prefer-inline')
  static void disableAutoEnterPip() =>
      AndroidHelper.disableAutoEnterPip(PlatformDispatcher.instance.engineId!);

  static (int, int)? maxScreenSize() {
    final jIArr = AndroidHelper.maxScreenSize();
    if (jIArr != null) {
      try {
        return (jIArr[0], jIArr[1]);
      } finally {
        jIArr.release();
      }
    }
    return null;
  }

  static void createShortcut(String id, String uri, String label, String path) {
    final jId = id.toJString();
    final jUri = uri.toJString();
    final jLabel = label.toJString();
    final jPath = path.toJString();
    try {
      AndroidHelper.createShortcut(jId, jUri, jLabel, jPath);
    } finally {
      jId.release();
      jUri.release();
      jLabel.release();
      jPath.release();
    }
  }
}
