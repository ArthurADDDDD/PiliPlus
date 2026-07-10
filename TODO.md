# TODO

## P0：应用内自更新 + GitHub Release 发布闭环（代码完成，待用户执行）

代码/workflow 已完成，详见 UPDATE.md「第十一轮」「第十二轮」与
`docs/RELEASE_GUIDE.md`。以下步骤必须由用户在自己账号下手动完成，
Agent 会话不会代为执行：

- [ ] 按 `docs/RELEASE_GUIDE.md` 第 1 节选定签名方案（推荐方案 A：
      沿用本地审计已确认的现有签名 `C:\Users\...\.android\debug.keystore`，
      alias `androiddebugkey`，免卸载迁移）。
- [ ] 备份该 keystore 至少两份离线副本（不要移动/删除原文件），转成
      Base64，在
      `https://github.com/ArthurADDDDD/PiliPlus/settings/secrets/actions`
      配置 `SIGN_KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS` /
      `KEY_PASSWORD` 四个 Secrets，配完删除明文 Base64 临时文件。
- [ ] 在
      `https://github.com/ArthurADDDDD/PiliPlus/settings/variables/actions`
      配置 `EXPECTED_SIGNING_CERT_SHA256`（方案 A 已知值：
      `2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349`，
      不是秘密，可以公开）。
- [ ] 确认 `pubspec.yaml` 的 `version:` 改成正式版本号（当前仍是占位的
      `2.0.9+1`），格式 `<name>+<buildNumber>`，`buildNumber` 需大于 `1`
      （本地审计确认的当前安装 versionCode 是 `1`）。
- [ ] 合并到 `main`，在 GitHub Actions 手动触发 Build workflow，`tag`
      填与 pubspec.yaml 版本一致的值（如 `v2.0.9+5103`），完成
      **第一次**正式 Release。
- [ ] 确认 workflow 的 job summary 显示 "signing: release keystore"
      （不是 "dev/debug"）、"expected/keystore/final APK 三个证书
      SHA-256" 一致、"all three match: true"，Release 页面有
      arm64-v8a/armeabi-v7a/x86_64 三个 APK 和 `SHA256SUMS.txt`。
- [ ] 在已安装现有版本（`com.example.piliplus`，versionCode `1`）的
      Pixel 10 Pro 上验证：自动检查更新弹窗正确出现、弹窗信息（tag/名称/
      说明/时间/版本号）完整、点「下载更新」正确打开 arm64-v8a 的下载
      链接、能正常**覆盖安装**（不弹"签名冲突"、不要求先卸载、本地数据
      保留）。
- [ ] 验证"tag 与 pubspec.yaml 版本不一致"、"缺签名 secret"、
      "tag 已存在"、"证书指纹与 EXPECTED_SIGNING_CERT_SHA256 不一致"
      四种场景下 workflow 确实会失败且不创建 Release（哪怕只手动试一种
      也好，用来确认 preflight 真的在生效，不是只在代码里看着对）。
- [ ] 发第二个正式版本（更高 buildNumber），验证第一版收到的自动更新
      提示确实生效、能正常升级到第二版。

以上完成前，**不得**在任何地方宣称"自更新已经过实机验证"或
"覆盖安装已经过实机验证"。

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
- **PiP 中已暂停 → 拖到关闭区不应恢复播放（第十一轮小修复，待真机验证）**：
  用户实测反馈过这个具体 bug；已修复 `PlPlayerController.refreshPlayer()`
  在 PiP surface 兜底重建路径上不再无条件 `play: true`，改为按当时真实
  播放状态恢复。需要真机验证：PiP 中暂停 → 拖到关闭区 → 确认后台没有
  重新开始播放；以及正常播放中拖到关闭区仍然正确暂停（不能因为这次修复
  引入回归）。

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
