# Update

## 2026-07-10（第十轮）

### 原生 PiP 中媒体重新加载后冻结（代码完成，待真机验证）

- 根因：`AndroidVideoController`（`third_party/media_kit_video`）由本 fork
  配置为 `androidAttachSurfaceAfterVideoParameters: false`，导致
  `onLoadHooks` 在每次媒体重新加载（分 P/清晰度/合集切换）后**无条件**把
  输出重新挂回 Flutter 内部纹理的 `wid`——完全绕过了旧版 `externalSurfaceActive`
  静态开关（该开关只在 `videoParams` 监听器里生效，`onLoadHooks` 从未检查过）。
  实际效果：PiP 期间切分 P/清晰度会让 mpv 输出静默抢回一个没人合成的 Flutter
  Surface，PiP 窗口画面冻结在旧帧（音频仍在播放）。
- 修复：为 `AndroidVideoController` 新增完整的外部 surface 所有权状态机：
  - `attachExternalSurface` / `updateExternalSurfaceSize` /
    `detachExternalSurfaceAndRestoreInternal` / `releaseExternalSurface`
    四个接口，取代原来的单个静态 bool。
  - `onUnloadHooks` 现在只是把「重挂待定」标记置位，不再丢失外部接管状态；
    `onLoadHooks` 与 `videoParams` 在媒体/Surface 就绪后自动把输出重新挂回
    **当前**外部 surface（不是 PiP 进入前缓存的旧 wid），加载中允许按
    libmpv 要求临时 `vo=null/wid=0`，加载完成后必定恢复
    `wid → android-surface-size → vo=gpu`。
  - 展开 PiP 时使用 `AndroidVideoController` 实时的内部 `wid`（而非
    `PipShell` 自己缓存的旧 `_flutterWid`）做恢复，PiP 期间产生的新内部
    Surface 也能被正确识别为「最新有效 Surface」。
  - 用一个单调递增的 `LoadGeneration`（generation/token）识别陈旧的异步
    `CreateSurface` 回调，防止其在 dispose 或更新的加载之后覆盖当前状态。
  - 纯状态机逻辑（无 Flutter/FFI 依赖）抽到独立文件
    `android_video_controller/external_surface_ownership.dart`，
    `third_party/media_kit_video/test/` 新增 56 条离线单测覆盖：
    正常内部播放、进入 PiP、PiP 中 unload/load、PiP 中连续多次切换、
    陈旧回调到达、PiP 展开、PiP 关闭、新视频页接管、Surface 销毁。
  - `lib/plugin/pl_player/pip_shell.dart` 改为使用新接口，不再直接读写
    `AndroidVideoController` 的静态字段。
- **本轮未连接真机，以上修复未经实机验证**，静态验证已完成：
  `dart format` / `flutter analyze`（相对本任务改动的文件 0 个新增问题）/
  相关 Dart 单测全部通过（详见下方“静态验证”小节）。

### 新增：可重复使用的功耗/发热监控工具（工具完成，待 Pixel 10 Pro 实测）

- 新增 `tools/monitor_piliplus_power.py`：纯标准库、不需要 root，通过本机
  `adb` 定时采样。`record` 子命令采集电池电量/温度/`current_now`/
  `voltage_now`/`charge_counter`/`energy_counter`（原始符号 + 绝对值 mA +
  估算功率 W，明确标注为估算）、应用 PID/CPU/RSS、系统总 CPU、屏幕开关、
  刷新率、PiP 状态、前台 Activity、热传感器（battery/skin/cpu/gpu/modem/
  ThermalStatus）、decoder 提示、播放器相关错误计数；开始/结束各保存一份
  `dumpsys battery/thermalservice/hardware_properties/display/
  activity_activities/media.metrics/media.codec/gfxinfo/meminfo/
  batterystats` 原始快照 + 过滤后的 logcat。任何字段读取失败都记为
  `unavailable`，不会让整次采集崩溃。`compare` 子命令支持目录或通配符，
  输出多组横向对比的 Markdown 表格，并主动标出时长不同/起始温度不同/
  缺采样率过高等不可直接比较的情况。默认不执行 `batterystats --reset`、
  不改亮度/刷新率、不切网络、不启停 App；`--reset-batterystats-before`
  作为显式可选项存在并会打印警告。
- 新增 `docs/POWER_TEST_GUIDE.md`：7 组测试矩阵（PiP 播放字幕/弹幕开关
  各组合、全屏播放、后台听声音、PiP 暂停亮屏基线），明确字幕与弹幕是两条
  不同渲染路径、不能混为一谈，并说明如何通过两两对比拆分出屏幕常亮/
  视频解码/PiP 合成/字幕/弹幕各自的功耗增量。
- 主要解析函数（`parse_dumpsys_battery`/`parse_power_supply_sysfs`/
  `parse_cpuinfo`/`parse_meminfo_rss`/`parse_thermal_status`/
  `parse_hardware_properties_temps`/`parse_foreground_activity`/
  `parse_codec_hint`/`count_logcat_errors`/`build_summary_markdown`/
  `build_compare_markdown` 等）有 56 条离线单元测试
  （`tools/tests/test_monitor_piliplus_power.py`），全部基于 fixture 文本，
  不需要连接设备即可运行，全部通过。
- **本轮完全没有运行过这个工具**（任务明确要求不得执行任何 `adb` 命令/
  不得检测手机是否连接），因此没有任何一条真实采样数据，也不能得出
  "省电/降温" 之类的结论——这些结论必须等用户在 Pixel 10 Pro 上按指南
  实测后才能下。

### 静态验证

- 本次改动涉及的 Dart 文件已用 `dart format` 格式化；未修改任何 Kotlin
  文件（修复完全在 Dart/media_kit 层完成，未触及 `PipActivity.kt`）。
- `flutter analyze`：相对本任务改动的三个文件（`pip_shell.dart`、
  `android_video_controller/real.dart`、`external_surface_ownership.dart`）
  0 个新增 info/warning/error；仓库其余部分原有 37 条历史 info 未处理
  （均与本任务无关，未扩大修改范围去清零）。
- `flutter test` / `dart test`：`third_party/media_kit_video/test/` 56
  条单测全部通过；主仓库本身目前没有 `test/` 目录（本轮之前就没有）。
- `python -m unittest discover -s tools/tests`：56 条单测全部通过。
- 修 `.gitignore` 里过宽的 `test*` 规则为 `/test*`（原规则会在仓库任意
  深度屏蔽 `test/` 目录，导致新增的 `third_party/media_kit_video/test/`
  无法被提交；改为只在仓库根目录生效，不影响原规则本身想屏蔽的内容——
  改动前仓库内没有任何被该规则实际跟踪/影响的文件）。
- **未能完成**：`flutter build apk --release --split-per-abi
  --target-platform android-arm64`。本轮运行在云端沙箱环境，已安装
  Flutter 3.44.5（与仓库版本一致）并可正常 `pub get`/`analyze`/`test`，
  但 Android SDK 的唯一官方分发渠道 `dl.google.com`/
  `android.googlesource.com` 被该环境出站网络策略拒绝（确认为策略拒绝
  而非超时），因此无法安装 Android SDK，构建止步于
  "No Android SDK found"。仓库的 `.github/workflows/build.yml` 有
  `workflow_dispatch` 手动触发的 android 构建+artifact 上传任务，是比
  云端会话本地构建更可靠的路径，本轮未触发（触发 CI 是有外部可见影响的
  操作，需要用户明确同意）。详见 AGENT_HANDOFF.md「Build Environment Note」。

## 2026-07-10（第九轮）

### 「个性化改动」设置页

- 新增独立设置页 `个性化改动`（设置首项），集中本 fork 新增的开关，便于查找：
  返回键进入原生画中画、返回时小窗播放、关闭画中画时暂停、使用旧版滑动调节、
  省电刷新率、应用图标。原版自带设置保持原位。
- 从「播放器设置」「音视频设置」移出上述我方新增项（原版 `后台画中画`/`画中画不加载弹幕` 保留原位）。

### 亮度滑动加 gamma 曲线

- 新版亮度调节改为在 gamma(2.2) 感知空间做相对位移，暗处更细腻、不再一滑就很亮，
  接近原版丝滑手感。音量保持相对线性。

### 应用图标可切换

- 新增设置 `应用图标`：可选 `国际版 bilibili`（默认）或 `原版 PiliPlus`。
- 实现：两个 `activity-alias`（各带图标）+ 运行时 `PackageManager.setComponentEnabledSetting`
  切换（先启用目标再禁用另一个，保证始终有 launcher 入口）；MAIN/LAUNCHER 从 MainActivity 移至 alias。
- 恢复原版 PiliPlus 图标资源为 `ic_launcher_piliplus`（矢量前景）。

### 图标尺寸微调

- bilibili 图标改为「白底填满 + logo 居中 62%」构图，消除方块白边接缝，与原版观感一致。

## 2026-07-10（第八轮）

### 新版滑动调节亮度/音量（默认）

- 旧版逐帧把 `delta.dy/level` 累加进 observable，受 setBrightness 回写抖动影响、
  起始基准不准 → 稍滑就跳到很亮。
- 新版：手势起点捕获当前亮度/音量值与 Y 坐标，按「相对起点的总位移」映射
  （约 0.75×视频高度滑满全程），跟手、不漂移，接近原版 B 站手感。默认启用。
- 设置新增 `使用旧版滑动调节`（默认关）：开启回到旧版逐帧累加。

### 修复应用内 PiP 拖到关闭区仍在播放

- 根因：上一版「延迟判展开」在拖到 X 时若 onStop 慢于定时器，会误判为展开
  → 走 onExpanded 保留播放，而非 onClosed 停止。
- 修复：onStop（离开 PiP 后触发即为关闭）立即取消待定的展开判定并走关闭
  （发媒体暂停 + PipShell.closed → Dart 暂停/上报/销毁）；展开判定加 `!isFinishing` 兜底。
- 新增 `PipShellNative` 的 EXPAND/CLOSE 判定日志。

### 图标放大

- 自适应前景层内容 62%→80%、传统图标 82%→92%，减少四周露出的白底。

## 2026-07-10（第七轮）

### 修复返回键 PiP 点击展开丢失视频

- 根因：展开判定原先依赖 `PipActivity.onResume`，但 PiP→全屏不一定重新触发 onResume，
  导致展开事件不发出 → 视频页未重新压栈（回不到播放页）、播放器仍在放（后台有声）、
  surface 切换中失效（视频消失）。
- 修复：改为 `onPictureInPictureModeChanged(false)` 后延迟 120ms 判定——
  Activity 未被 stop/finish 即为展开（发 expanded + finish），被停止则由 onDestroy 走关闭。
  新增 onStart/onStop 跟踪 `isStopped`。
- 展开路径 Dart 侧同步清 `AndroidHelper.isPipMode`，避免重进视频页按 PiP 布局构建。

### 两种 PiP 记忆统一 & 弹幕（结论：不做）

- 现象：回桌面 PiP（MainActivity，带弹幕）与返回键 PiP（PipActivity，无弹幕）
  大小/位置记忆各自独立（Android 按 Activity 组件记忆，无法用 API 合并）。
- 分析：统一记忆需同组件；但返回键要「回上一页 + 不露出别的 app」必须用独立 PipActivity；
  而 PipActivity 内加弹幕需第二 FlutterEngine（破坏单例）或原生重写弹幕，均为大改高风险。
- 结论：保持现状，回桌面 PiP 保留弹幕，返回键 PiP 纯原生；两者各自记忆自己的大小位置。

## 2026-07-10（第六轮）

### 应用图标 & PiP 默认位置

- 应用图标替换为白色版 bilibili（来源 `icon.png`）：
  重生成 `mipmap-*/ic_launcher.png`（传统白底方形）与
  `drawable-*/ic_launcher_foreground.png`（自适应前景层），删除旧矢量前景 XML，
  移除 adaptive-icon 的 monochrome（彩色 logo 不适合单色主题图标）。
- PiP 默认位置/大小：曾尝试用 `setSourceRectHint` 提示右上角+更大区域，
  真机验证 Pixel 忽略该提示的落点（仍落右下角、中等大小），已撤销该无效改动。
  结论：Android 无公开 API 指定 PiP 最终落点/大小，由系统决定并记忆用户上次拖动/缩放。
  上一轮的宽高比归一化（`normalizePipAspect`）已让「同类 PiP」的大小记忆更易保留。

## 2026-07-09（第五轮）

### PiP 壳体验修复

- 修复「PiP 期间切换新视频后页面渲染成 PiP 布局（无详情/仅视频）」：
  PipShell.hide 现在同步清 `AndroidHelper.isPipMode`（原先等 PipActivity onDestroy 才清，
  新页面已按 PiP 布局构建完）；PipActivity.finishSilently 也立即清标志。
- 缩短进入 PiP 时的黑屏：surface 切换不再先 `vo=null`，
  改为与 media_kit 运行时重挂一致的 `android-surface-size → wid → vo=gpu` 顺序。
- PiP 宽高比归一化（`PageUtils.normalizePipAspect`）：接近 16:9 / 9:16 的视频统一取
  标准比例，避免逐视频微小比例差异重置系统记忆的捏合大小。两种 PiP 路径共用。
- 已知限制（Android 平台行为）：系统对 PiP 大小的记忆按 Activity 组件区分，
  「回桌面 PiP」（MainActivity）与「返回键 PiP」（PipActivity）交替使用时记忆会被清除。
  彻底统一需把回桌面路径也改走 PipActivity（代价：回桌面 PiP 失去弹幕与手势变形动画），待用户决策。

## 2026-07-09（第四轮）

### PiP 壳修复与统一

- 修复 PiP 黑屏根因：`AndroidVideoController` 的 videoParams 监听会把 libmpv 输出
  抢回 Flutter 纹理。将 `media_kit_video` 转为本地维护（`third_party/media_kit_video`，
  基于原 fork version_1.2.5），新增 `externalSurfaceActive` 开关，PiP 壳接管期间挂起自动重挂。
- 修复「拖到关闭区被误判为展开」：展开判定改为 离开 PiP 后紧跟 onResume；
  关闭走 onDestroy 兜底。
- 统一关闭行为：返回键 PiP 拖到关闭区后，
  - 原生侧按「关闭画中画时暂停」设置直接经媒体会话发送暂停（与回桌面 PiP 同一开关）；
  - Dart 侧同步 `pause=yes` 立即静音，并上报进度、销毁播放器、清媒体会话。
- 新增原生日志探针：`PipShellNative`（生命周期/surface 事件）、`PipShellDart`（mpv 切换结果）。
- 说明：Android 无公开 API 预设 PiP 窗口默认大小；系统会记住用户上次捏合缩放，
  已在设置项说明中注明。

## 2026-07-08（第三轮）

### 返回键进入系统原生画中画（PipShell）

- 用户实测否决应用内小窗方案，要求系统原生 PiP。采用「原生 PiP 壳 + surface 热切换」：
  - 新增原生 `PipActivity`（同 task、excludeFromRecents、TextureView）。
  - Android 13+ 用 `ActivityOptions.makeLaunchIntoPip` 直接以 PiP 形态启动，无全屏闪现；
    低版本回退为 onCreate 立即 `enterPictureInPictureMode`。
  - 返回键：视频页正常 pop（复用 detach 机制），libmpv 输出 `wid` 从 Flutter 纹理
    热切换到 PipActivity 的 TextureView（`vo=null → android-surface-size → wid → vo=gpu`，
    与 media_kit 自身处理尺寸变化的机制一致），播放不重建、不缓冲。
  - PiP 为系统原生窗口：原生圆角/缩放/拖动/关闭区，快退/播放暂停/快进 RemoteActions
    （经 `AndroidHelper.pipShellActivity` 定向更新）。
  - 展开：输出切回 Flutter 纹理（PipShell 保存的原 wid；拿不到时 `refreshPlayer()` 兜底），
    无缝重进视频页（复用 fromMiniPlayer 衔接）。
  - 关闭（拖到关闭区）：上报进度、销毁播放器、清媒体会话。
  - Surface 销毁竞态：`onSurfaceTextureDestroyed` 返回 false，Dart 先摘 mpv 输出
    再回调原生释放 Surface（全局引用延迟 5s 删除，与 media_kit 一致）。
  - 已知取舍：PiP 窗口内不显示弹幕（弹幕由 Flutter 渲染，无法进入原生窗口）。
- 设置：
  - 新增 `返回键进入原生画中画`（默认开启）。
  - `返回时小窗播放` 保留为备选（默认关闭，仅上一项关闭时生效）。
- 构建与安装：
  - `app-arm64-v8a-release.apk` SHA256：
    `D555058F6492DFFD5CA8F8763AAE75AA4DDEDAEBC53C767D463E07409CE5E44B`
  - 已 ADB 安装到 Pixel 10 Pro，启动无 `FATAL EXCEPTION`。

## 2026-07-08（第二轮）

### 返回键小窗播放（P0 路线 A）

- 经调研确认：官方 B 站「返回后继续播放」实际是应用内小窗，不是系统 PiP；
  单 Activity 架构下「返回键系统 PiP 覆盖在本 app 上一页之上」在平台机制上不可行。
- 采用路线 A：新增应用内小窗播放器（`lib/plugin/pl_player/mini_player.dart`）：
  - 视频播放中按返回键，页面正常返回上一页，播放器以浮动小窗继续播放（同一引擎复用现有纹理，无重建/缓冲）。
  - 小窗默认显示弹幕（`画中画不加载弹幕` 开启时隐藏）。
  - 小窗可拖动、松手自动吸附左右边缘；点按显示 播放/暂停、展开、关闭 控件。
  - 展开无缝回到视频页（同 cid 直接衔接存活播放实例，不重新 setDataSource）。
  - 关闭小窗时上报观看进度并销毁播放器、清理媒体会话。
  - 小窗期间回桌面仍走系统原生 PiP（auto-enter 保持注册），系统 PiP 中小窗切换为全屏纯视频渲染。
  - 小窗期间补齐后台暂停策略（与页面内播放器一致，尊重 `后台播放` 开关与 PiP 状态）。
- 设置变更：
  - 新增播放设置 `返回时小窗播放`（默认开启）。
  - 移除 `返回键进入原生画中画（实验）` 设置项（迁移版本 4 已把旧开关强制关闭，行为代码已删除）。
- 保护逻辑：
  - 视频页下方还有其它视频页（页内再开视频）时不进小窗，避免状态冲突。
  - 任何新页面接管播放器（`getInstance`）时小窗自动退场。

### 构建与验证（第二轮）

- 已构建 arm64 release APK：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（22.9MB）。
- SHA256：`A3C63636FA7B112530530CA7A48914B2503C86A82D31BF3948145BCC9B7EC327`
- 已通过 ADB 安装到 Pixel 10 Pro（设备 59181FDCH001HZ），启动正常，
  logcat 无 `FATAL EXCEPTION` / `AndroidRuntime` 崩溃。
- 小窗交互的真机验证清单见 TODO.md P0 一节。

## 2026-07-08

### Android 17 / Tensor 优化

- 在 Android 原生层新增应用窗口 60Hz 刷新率请求。
- 新增 `MethodChannel("piliplus/android")`，用于 Dart 与原生层同步 Android/PiP 设置。
- 在视频设置中新增 `Android 17/Tensor 省电刷新率`。
- 已在 Pixel 10 Pro 上验证：应用前台时系统可以给 PiliPlus UID 下发 60Hz frame-rate override。
- 调整 Android 默认播放负载：
  - Wi-Fi 默认视频画质：1080P。
  - 蜂窝网络默认视频画质：720P。
  - Android 默认解码偏好：HEVC、AVC、AV1。
- Android 17 迁移路径默认关闭播放器预初始化和超分辨率。
- 保留后台音频服务和高音质默认值，避免省电策略影响锁屏听歌、PiP 听歌。

### PiP 行为

- 保留上滑回桌面的系统原生 PiP。
- 新增 `关闭画中画时暂停`：
  - 系统原生 PiP 被拖到 Android 关闭区域后，会通过媒体会话发送暂停动作。
- 新增 Android 原生 PiP 状态回调到 Dart：
  - Flutter 播放器可以感知原生 PiP 进入/退出。
  - PiP 默认保留弹幕；只有开启 `画中画不加载弹幕` 时才隐藏弹幕。
- Android 生命周期暂停检查增加短延迟，避免把 PiP 进入误判为普通后台暂停。
- 修复 Android 12+ 自动进入 PiP 在播放暂停/恢复后不会重新注册的问题。

### 返回键 PiP 实验

- 曾尝试让播放页返回键直接进入系统原生 PiP。
- 结果不符合预期：
  - PiliPlus 当前只有一个 Android `MainActivity`。
  - 这个 Activity 进入 PiP 后，系统露出的是上一个 app，而不是 PiliPlus 上一页。
- `返回键进入原生画中画（实验）` 现在默认关闭。
- 迁移版本 4 会把已安装用户的该开关强制关掉，避免继续出现错误体验。

### 新增设置

- 播放设置：
  - `后台画中画`
  - `返回键进入原生画中画（实验）`
  - `关闭画中画时暂停`
  - `画中画不加载弹幕` 继续有效
- 视频设置：
  - `Android 17/Tensor 省电刷新率`

### 构建与验证

- 已构建 arm64 release APK：
  - `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- 最新 SHA256：
  - `3D610464833C6FE66C19CA0AD254A20FD57EC1A461D8B30E7C4F7F01CB2C10B8`
- 已通过 ADB 安装到 Pixel 10 Pro。
- 已验证应用可启动，检查日志中未出现 `FATAL EXCEPTION` / `AndroidRuntime` 崩溃关键字。

