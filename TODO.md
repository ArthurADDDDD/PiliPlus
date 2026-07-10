# TODO

## P0：真机验证「返回键进入原生画中画」（PipShell，路线 C）

- 返回键 → 系统 PiP 直接出现（无全屏黑屏闪现）、上一页正常、播放/声音不间断。
- PiP 原生交互：捏合/菜单缩放、拖动、双击切换大小。
- PiP 控件：快退 10s / 播放暂停 / 快进 10s；暂停后图标状态刷新。
- 展开（点 PiP 中央展开按钮）→ 回视频页无缝衔接、画面回到页面内、进度正确。
- 拖到底部关闭区 → 播放停止、媒体通知消失、历史进度已上报。
- PiP 期间锁屏/解锁 → 恢复后画面正常。
- PiP 期间在 app 里点开新视频 → PiP 壳自动消失、新视频正常渲染在页面内。
- **PiP 期间切换分 P/清晰度/合集切换（本轮重点修复项，代码完成，待真机验证）**：
  之前会把输出切回 Flutter 纹理导致 PiP 冻结在旧画面（有声音无画面）。
  已在 `AndroidVideoController`（`third_party/media_kit_video`）新增
  外部 surface 所有权状态机（`attachExternalSurface` /
  `updateExternalSurfaceSize` / `detachExternalSurfaceAndRestoreInternal` /
  `releaseExternalSurface`，纯逻辑部分抽到 `external_surface_ownership.dart`
  并有离线单测），`onUnloadHooks/onLoadHooks/videoParams` 现在会在媒体重载后
  自动重挂回当前有效的 PiP surface，而不是抢回 Flutter 纹理或依赖旧的
  `_flutterWid` 缓存。需要真机验证：
  - PiP 中切换分 P → 画面正常切换、不冻结、不黑屏。
  - PiP 中切换清晰度 → 同上。
  - PiP 中连续快速切换多次（分 P/清晰度连打）→ 不冻结、不崩溃、无 Surface 泄漏。
  - 切换过程中点展开 → 正确回到页面内且画面不是旧帧。
  - 切换过程中拖到关闭区 → 正常停止，无残留播放器/Surface 引用。
- 竖屏视频返回 → PiP 比例正确（9:16 类）。
- 反复进出 PiP 多次 → 无 Surface 泄漏/崩溃（重点观察 logcat EGL/mpv 报错）。

## 已完成：返回键小窗播放（原 P0，路线 A）

调研结论（2026-07-08）：

- Android 原生 PiP 是 Activity 级能力；PiliPlus 单 `MainActivity` 下，
  「返回键系统 PiP 覆盖在本 app 上一页之上」在平台机制上不可行。
- 官方/国际版 B 站的「返回继续播放」实际是应用内小窗，系统 PiP 只在离开 app 时出现。
- 独立播放 Activity + 第二 FlutterEngine 的路线（路线 B）技术上可行但代价大：
  GetX/service 单例跨 isolate 不共享、media_kit 纹理无法跨 engine 迁移（需重建+seek）、
  Hive 双 isolate 并发风险。如未来仍想要，先做最小 spike 验证播放器重建间隙。

已实现（待真机验证，见下）：

- `lib/plugin/pl_player/mini_player.dart` 应用内小窗；返回键 detach、展开无缝衔接、
  关闭上报进度；小窗期间保留系统 PiP auto-enter 与后台暂停策略。
- 设置 `返回时小窗播放`（默认开启）替换 `返回键进入原生画中画（实验）`。

## P0：真机验证小窗播放（Pixel 10 Pro）

- 返回键 → 小窗出现、上一页正常显示、播放不间断。
- 拖动吸边、点按控件（播放/暂停、展开、关闭）。
- 展开回视频页：无重新缓冲、进度/弹幕/字幕正常。
- 关闭小窗：播放停止、通知栏媒体会话清理、历史进度已上报。
- 小窗中回桌面 → 系统 PiP 正常且画面为纯视频；从 PiP 返回 app 恢复小窗。
- 小窗中新开视频/直播 → 小窗自动退场，新页面正常播放。
- 关闭「后台播放」时：小窗 + 回桌面（无 PiP 场景）应在约 0.6s 后暂停。
- 多 P/合集切换后返回 → 小窗展开应回到当前分 P。
- 竖屏视频（isVertical）小窗比例正确。

## P1：Tensor / Android 17 实测验证

- 长时间播放下记录 Pixel 10 Pro 发热趋势。
- 对比 60Hz 省电刷新率开关开/关：
  - 机身温度
  - 电量消耗
  - 掉帧
  - CPU/GPU 负载
  - 解码器选择
- 分别测试 720P、1080P、4K、HDR。
- 分别测试 Wi-Fi 与蜂窝网络。
- 重点确认锁屏播放、后台播放、PiP 听歌不受影响。

**工具已完成（待 Pixel 10 Pro 实测，本轮未运行）**：新增
[`tools/monitor_piliplus_power.py`](../tools/monitor_piliplus_power.py)，
纯标准库、不需要 root，`record` 子命令定时采样电池/电流/温度/CPU/内存/
刷新率/PiP 状态/热传感器/decoder 提示/错误计数并生成 `SUMMARY.md`，
`compare` 子命令做多组横向对比。配套测试矩阵见
[`docs/POWER_TEST_GUIDE.md`](../docs/POWER_TEST_GUIDE.md)，用于拆分
屏幕常亮/视频解码/PiP合成/字幕/弹幕各自的功耗贡献。主要解析函数有离线
单测（`tools/tests/test_monitor_piliplus_power.py`，56 条，无需连接设备
即可运行）。**本轮未连接真机，未运行过任何一次实际采样，没有任何测试
数据，因此不能得出任何"更省电/更凉快"的结论**——上面的验证项仍然是
待办，需要用户在 Pixel 10 Pro 上按 `docs/POWER_TEST_GUIDE.md` 的矩阵
实际跑一遍。

可用 ADB 检查（本工具已自动化以下大部分）：

- `dumpsys display`
- `dumpsys thermalservice`
- `dumpsys batterystats`
- `dumpsys media.metrics`
- `logcat` 过滤播放器、媒体会话、音频服务错误

## 已调研（暂不实现）：微信分享卡片

- 现状：`ShareUtils.shareText()` → `share_plus` ACTION_SEND 纯文本，微信只收到文字+链接。
- 原版「贴纸/网页卡片链接」需接入微信开放平台 SDK（`com.tencent.mm.opensdk`），
  且 AppID 必须绑定本包名 `com.example.piliplus` + 当前签名指纹；
  微信校验调用方包名+签名，借用 bilibili 官方 AppID 会被拒。
  个人开发者通常无法注册移动应用（需企业资质+认证费+审核）→ 该方案对个人包不可行。
- 可落地替代（用户暂缓）：分享海报图（封面+标题+UP+二维码），
  用现有 `SharePlus` 图片分享（`image_utils.dart` 已有 `ShareParams(files:[XFile])` 范式）即可，
  无需 SDK/AppID。若之后要做，从这里入手。
- 用户 2026-07-10 决定：暂时不改，保持纯文字+链接。

## P2：收尾清理

- 项目结束后删除 `D:\CodexTemp` 下的临时工具链。
- 决定是否记录 APK 哈希，构建产物本身通常不提交。
- 提交前检查 `AndroidHelper.java` 当前是否只是行尾差异。
- `Pref.pipOnBack` 仅剩迁移逻辑引用，确认无老用户残留问题后可彻底删除该 key。

## 阻塞项：本轮云端环境未能完成的 arm64 APK 构建

- 2026-07-10 本轮在 Anthropic 管理的云端 Ubuntu 会话中开发，非用户本机
  （见 AGENT_HANDOFF.md）。已安装 Flutter 3.44.5（与仓库要求版本一致）并
  完成 `flutter pub get` / `dart format` / `flutter analyze`（0 个新增
  问题）/ 相关 Dart 单测（全部通过）。
- **Android SDK 无法在该云端环境安装**：`dl.google.com` 与
  `android.googlesource.com`（Android SDK platform-tools/build-tools/NDK
  的唯一官方分发渠道）被该环境的出站网络策略拒绝（403 policy denial，
  非超时/证书问题，已通过代理自身状态日志确认），按环境规则不应绕过策略
  限制去找镜像源。`flutter build apk` 因此在 "No Android SDK found" 处
  失败，**本轮未产出任何 APK**，也无法用 `keytool` 报告签名信息。
- 仓库存在 `.github/workflows/build.yml`，其 `android` job 支持
  `workflow_dispatch` 手动触发，会构建 arm64/armv7/x86_64 release APK
  并作为 workflow artifact 上传（若配置了 `SIGN_KEYSTORE_BASE64` 等
  secrets 则为正式签名，否则为默认签名）——这是比云端会话本地构建更
  可靠的产出 APK 的路径，需要仓库所有者在 GitHub Actions 页面手动触发
  （本轮未触发，触发 CI 属于有外部可见影响的操作，需用户明确同意）。
- 待办：换一个能访问 Android SDK 分发源的环境（用户本机、或出站策略
  允许 `dl.google.com` 的 CI）完成 arm64 release APK 构建，并用
  `keytool -printcert -jarfile <apk>` 确认签名是否与用户现有安装版本
  一致（云端生成的 APK 若走 debug 签名将无法覆盖安装正式签名的旧版本）。
