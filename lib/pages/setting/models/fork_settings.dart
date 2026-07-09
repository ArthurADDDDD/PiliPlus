import 'dart:io' show Platform;

import 'package:PiliPlus/models/common/app_icon_type.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 本 fork（Pixel/Tensor 个人优化版）新增的设置，集中于此便于查找。
/// 原版自带的设置仍保留在各自原页面。
List<SettingsModel> get forkSettings => [
  if (Platform.isAndroid)
    PopupModel<AppIconType>(
      title: '应用图标',
      leading: const Icon(Icons.apps_outlined),
      value: () => Pref.appIconType,
      items: AppIconType.values,
      onSelected: (value, setState) {
        GStorage.setting
            .put(SettingBoxKey.appIconType, value.index)
            .whenComplete(setState);
        PiliAndroidHelper.setAppIcon(value.isBilibili);
        SmartDialog.showToast('图标已切换，桌面可能需要片刻刷新');
      },
    ),
  if (Platform.isAndroid) ...[
    const SwitchModel(
      title: '返回键进入原生画中画',
      subtitle: '视频播放中按返回键，回到上一页并以系统原生画中画继续播放（画中画内不显示弹幕）',
      leading: Icon(Icons.picture_in_picture_alt_outlined),
      setKey: SettingBoxKey.pipOnBackNative,
      defaultVal: true,
    ),
    const SwitchModel(
      title: '返回时小窗播放',
      subtitle: '上一项关闭时生效：返回后以应用内小窗继续播放（可显示弹幕）',
      leading: Icon(Icons.branding_watermark_outlined),
      setKey: SettingBoxKey.miniPlayerOnBack,
      defaultVal: false,
    ),
    const SwitchModel(
      title: '关闭画中画时暂停',
      subtitle: '将系统画中画（回桌面或返回键触发）拖到关闭区域后，停止播放\n提示：画中画窗口大小由系统记忆上次捏合缩放的结果，无法在应用内预设',
      leading: Icon(Icons.pause_presentation_outlined),
      setKey: SettingBoxKey.pauseOnPipDismiss,
      defaultVal: true,
      onChanged: PiliAndroidHelper.setPauseOnPipDismiss,
    ),
  ],
  const SwitchModel(
    title: '使用旧版滑动调节',
    subtitle: '默认使用接近原版 B 站的相对调节（带 gamma 曲线，暗处更细腻、更跟手）；开启则回到旧版逐帧累加调节',
    leading: Icon(Icons.swipe_vertical_outlined),
    setKey: SettingBoxKey.legacySlideAdjust,
    defaultVal: false,
  ),
  if (Platform.isAndroid)
    SwitchModel(
      title: 'Android 17/Tensor 省电刷新率',
      subtitle: '限制本应用以 60Hz 渲染，降低 Pixel/Tensor 发热；关闭后恢复系统自动刷新率',
      leading: const Icon(Icons.battery_saver_outlined),
      setKey: SettingBoxKey.androidPowerSaveMode,
      defaultVal: Pref.androidPowerSaveMode,
      onChanged: (value) {
        PiliAndroidHelper.setPowerSaveRefreshRate(value);
        if (!value) {
          GStorage.setting.delete(SettingBoxKey.displayMode);
          FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
        }
      },
    ),
];
