import 'dart:io' show Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/update/release_update_logic.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class Update {
  // 检查更新：只看本 fork（Constants.githubOwner/githubRepo）的最新正式 Release，
  // 不看 Actions artifact、不看 draft、默认不看 prerelease。
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestRelease,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'user-agent': Constants.appName,
          },
          extra: {'account': const NoAccount()},
        ),
      );
      final result = parseLatestReleaseResponse(
        res.data,
        statusCode: res.statusCode,
      );
      switch (result) {
        case LatestReleaseNotFound():
          // 仓库还没有发布正式版本：自动检查静默跳过，手动检查明确提示。
          if (kDebugMode) debugPrint('checkUpdate: no release published yet');
          if (!isAuto) {
            SmartDialog.showToast('当前仓库还没有发布正式版本');
          }
        case LatestReleaseError(:final message):
          if (kDebugMode) debugPrint('checkUpdate failed: $message');
          if (!isAuto) {
            SmartDialog.showToast('检查更新失败：$message');
          }
        case LatestReleaseFound():
          _handleFound(result, isAuto);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
      if (!isAuto) {
        SmartDialog.showToast('检查更新失败，请检查网络后重试');
      }
    }
  }

  static void _handleFound(LatestReleaseFound release, bool isAuto) {
    final decision = decideShouldPromptUpdate(
      currentBuildNumber: BuildConfig.versionCode,
      currentBuildTimeEpochSeconds: BuildConfig.buildTime,
      releaseTag: release.tagName,
      releasePublishedAt: release.publishedAt,
      releaseCreatedAt: release.createdAt,
    );
    if (kDebugMode && decision.usedDateFallback) {
      debugPrint(
        'checkUpdate: tag "${release.tagName}" is not in <name>+<build> '
        'form, falling back to timestamp comparison',
      );
    }
    if (!decision.shouldPrompt) {
      if (!isAuto) {
        SmartDialog.showToast('已是最新版本');
      }
      return;
    }
    _showUpdateDialog(release, isAuto);
  }

  static void _showUpdateDialog(LatestReleaseFound release, bool isAuto) {
    SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        Widget metaLine(String text) => Text(
          text,
          style: TextStyle(color: colorScheme.outline, fontSize: 12),
        );
        return AlertDialog(
          title: const Text('🎉 发现新版本'),
          content: SizedBox(
            height: 320,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.tagName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (release.name != null &&
                      release.name!.isNotEmpty &&
                      release.name != release.tagName) ...[
                    const SizedBox(height: 2),
                    Text(release.name!),
                  ],
                  const SizedBox(height: 6),
                  metaLine(
                    '当前版本：${BuildConfig.versionName}+${BuildConfig.versionCode}',
                  ),
                  metaLine('新版本：${release.tagName}'),
                  if ((release.publishedAt ?? release.createdAt) case final t?)
                    metaLine('发布时间：$t'),
                  const SizedBox(height: 8),
                  if (release.body != null && release.body!.isNotEmpty)
                    Text(release.body!),
                ],
              ),
            ),
          ),
          actions: [
            if (isAuto)
              TextButton(
                onPressed: () {
                  SmartDialog.dismiss();
                  GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                },
                child: Text(
                  '不再提醒',
                  style: TextStyle(color: colorScheme.outline),
                ),
              ),
            TextButton(
              onPressed: SmartDialog.dismiss,
              child: Text('取消', style: TextStyle(color: colorScheme.outline)),
            ),
            TextButton(
              onPressed: () => PageUtils.launchURL(_releasePageUrl(release)),
              child: const Text('查看 Release'),
            ),
            TextButton(
              onPressed: () => onDownload(release),
              child: const Text('下载更新'),
            ),
          ],
        );
      },
    );
  }

  static String _releasePageUrl(LatestReleaseFound release) {
    if (release.htmlUrl case final url? when url.isNotEmpty) {
      return url;
    }
    return '${Constants.sourceCodeUrl}/releases/latest';
  }

  // 下载适用于当前系统的安装包：
  // Android 按 supportedAbis 顺序匹配 *.apk 资产；找不到匹配资产时打开
  // Release 页面（html_url，缺失时兜底 releases/latest）而不是静默失败。
  // 不在 App 内静默下载/安装 APK，交给系统浏览器/下载管理器处理。
  static Future<void> onDownload(LatestReleaseFound release) async {
    SmartDialog.dismiss();
    try {
      ReleaseAsset? asset;
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        asset = pickAndroidApkAsset(release.assets, androidInfo.supportedAbis);
      } else {
        final plat = Platform.operatingSystem;
        for (final candidate in release.assets) {
          if (candidate.name.toLowerCase().contains(plat)) {
            asset = candidate;
            break;
          }
        }
      }
      if (asset != null) {
        PageUtils.launchURL(asset.downloadUrl);
        return;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
    }
    PageUtils.launchURL(_releasePageUrl(release));
  }
}
