# Update

## 2026-07-10（第十二轮）

### 沿用现有签名密钥 + 证书指纹锁定（代码完成，待用户配置 Secrets/Variable 并实测）

- 修正上一轮文档里隐含的结论："当前 APK 用 debug.keystore 签名，所以必须新建
  release key 并卸载重装"——这个结论不对。Android 判断能否覆盖安装只看
  `applicationId` + 签名证书是否一致，跟密钥文件叫 `debug.keystore` 还是
  `release.jks`、alias 叫 `androiddebugkey` 还是别的名字**无关**。用户本地
  审计确认了当前安装 APK 的证书 SHA-256（`2d02cc05ff51a2b2c020fe41cc764d3a
  a77b0d18448807e78a9b447505a1e349`）与本地仍然保留的
  `C:\Users\...\.android\debug.keystore`（alias `androiddebugkey`）完全对应，
  因此只要 GitHub Actions 用**同一个** keystore 文件和 alias 签名，就能继续
  产生能覆盖当前安装的正式 Release，不需要卸载、不会丢失数据。
- `docs/RELEASE_GUIDE.md` 第 1 节据此重写为「方案 A（推荐，沿用现有签名，
  免卸载迁移）/ 方案 B（新建专用 release key，首次需卸载）」两选一，
  明确写清楚方案 A 的风险（debug 密钥通常弱密码，安全性依赖文件不泄漏，
  不适合大规模公开商业分发）——但对个人维护的私有 fork 可接受，前提是
  风险写清楚，不隐瞒。
- 新增签名证书指纹锁定，防止以后误传另一把有效但不同的 keystore：
  - 新增 `lib/scripts/signing_fingerprint.ps1`：可 dot-source 复用的纯
    PowerShell 库，`ConvertTo-NormalizedFingerprint`（统一转小写、去冒号/
    空格、校验 64 位十六进制）、`Test-FingerprintMatch`、
    `ConvertFrom-KeytoolCertOutput`/`ConvertFrom-ApksignerCertOutput`
    （从 `keytool -list -v`/`apksigner verify --print-certs` 的文本输出里
    解析 SHA-256 行）为纯函数，`Get-KeystoreCertFingerprint`/
    `Get-ApkCertFingerprint` 为调用 keytool/apksigner 的薄封装。不引入
    Pester 等第三方依赖。
  - 新增 `lib/scripts/signing_fingerprint.tests.ps1`：不依赖任何框架的
    离线测试脚本，覆盖：小写无冒号、大写无冒号、大写带冒号、前后空格、
    内部空格、非法字符、少于/多于 64 位、空/null 输入、指纹一致、指纹
    不一致（含两侧任一格式非法的情况）、keytool 输出解析成功/失败、
    apksigner 输出解析成功/失败、端到端"跟 EXPECTED_SIGNING_CERT_SHA256
    风格输入比对"场景。**本轮沙箱环境没有 `pwsh`，无法实际运行**（与上一轮
    `release_version.ps1` 同样的限制），只做了逐行人工审阅，需要在有
    `pwsh` 的环境（本地或 CI）里实际跑一遍才能确认真正通过。
  - `.github/workflows/build.yml` 正式发布路径新增：
    1. 读取新的 Repository **Variable**（不是 Secret，证书指纹本身不是
       秘密）`EXPECTED_SIGNING_CERT_SHA256`，构建前先校验格式合法。
    2. 写入 keystore 之后、Flutter 构建之前，用 `keytool` 读取实际证书
       指纹，与预期比对，不一致直接失败（不会浪费一次完整构建才发现
       传错了 keystore）。
    3. APK 构建完成后，用 `apksigner` 再读一次每个 APK 的实际证书指纹，
       与预期比对，不一致直接失败（防止 Gradle 实际用错 signingConfig
       这种"keystore 本身没问题、但没生效"的情况）。
    4. 以上任一环节缺配置/格式非法/alias 不存在/keystore 打不开/指纹不
       一致，都会让 workflow 失败，不构建正式 Release、不上传正式 APK、
       不创建 tag、不创建 Release、不回退 debug 签名——错误信息包含
       期望/实际指纹，不输出密码/Base64/私钥内容。
  - Job summary 新增字段：`applicationId`、预期证书 SHA-256、keystore 实际
    证书 SHA-256、最终 APK 证书 SHA-256、三者是否一致。
- 文档同步更新 `docs/RELEASE_GUIDE.md`（新增 1.1 方案 A 全套步骤——备份、
  确认证书、转 Base64、配置 4 个 Secret + 1 个 Variable；1.2 方案 B；
  新增「5. 版本兼容说明」写明当前安装 versionCode 是 `1`）、`README.md`、
  `TODO.md`、`AGENT_HANDOFF.md`。
- **本轮没有**：读取用户本地文件、要求用户上传 keystore 或粘贴 Base64、
  触发任何 GitHub Actions、配置任何 Secrets/Variables、创建 tag、创建
  Release、安装 APK、运行 ADB、合并到 `main`、生成新的 keystore、修改
  证书指纹的实际值（`2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78
  a9b447505a1e349` 原样引用自用户提供的本地审计结果）。

## 2026-07-10（第十一轮）

### PiP 关闭态误恢复播放（小修复，代码完成，待真机验证）

- 用户实测反馈：PiP 中已暂停的视频，拖到关闭区后会在后台重新开始播放；
  播放中拖到关闭区则表现正常（正确暂停）。
- 根因分析（未接入真机 logcat，基于代码走查的最可能解释）：PiP 展开/关闭
  的原生检测在极少数时序下可能把"关闭"误判为"展开"，触发
  `PipShell.onExpanded()` 走 `detachExternalSurfaceAndRestoreInternal()`；
  当内部 Flutter surface 尚未就绪时会退回 `PlPlayerController.refreshPlayer()`
  兜底重建输出——而 `refreshPlayer()` 原来**无条件** `play: true`，会把一个
  本来暂停的播放器重新播放起来。播放中发生同样的误判不会被用户注意到
  （反正本来就在播），暂停时则会被明显感知为"关闭后又开始放"。
- 修复：`refreshPlayer()` 新增可选 `play` 参数（默认仍为 `true`，不影响
  另一处调用方——直播/URL 断线重连场景，那里恢复播放是正确行为）；
  `PipShell._restoreFlutterSurface()` 改为显式传入
  `play: ctr.playerStatus.isPlaying`，按兜底触发那一刻的真实播放状态重建
  输出，不再强制播放。
- 涉及文件：`lib/plugin/pl_player/controller.dart`、
  `lib/plugin/pl_player/pip_shell.dart`。
- 本轮未连接真机，此修复未经实机验证；建议下一轮真机测试时补充这个具体
  场景（PiP 中暂停 → 拖到关闭区 → 确认不会在后台重新播放）。

### 应用内自更新 + GitHub Release 发布闭环（代码完成，待用户执行首次发布与实机验证）

**更新检查逻辑重写**（`lib/utils/update.dart` +
新增 `lib/utils/update/release_update_logic.dart`）：

- 仓库 owner/name 集中定义到 `Constants.githubOwner`/`Constants.githubRepo`
  （`lib/common/constants.dart`），`Api.latestRelease`（`lib/http/api.dart`）
  与 `Constants.sourceCodeUrl` 都从这里派生，不再各自硬编码。
- 请求端点从 `GET /releases`（取列表第一项）改为 `GET /releases/latest`
  （单个最新正式 Release），天然排除 draft，GitHub 本身也不会在这个接口
  返回 prerelease；`parseLatestReleaseResponse()` 额外做了 draft/prerelease
  的防御性二次过滤（即便未来换成能拿到 draft/prerelease 的接口也不会误报）。
  404（还没发布过 Release）与其他错误（网络失败、响应格式异常、GitHub 报错）
  被明确分类，分别给用户不同提示，不再统一吞掉。
- 版本比较不再依赖 `BuildConfig.buildTime < Release.created_at`：新增纯
  `ReleaseVersion` 解析器，解析 `v2.0.9+5103` / `2.0.9+5103` 形式的 tag，
  **只用 build number 整数比较**判断是否需要提示更新——build number 相等/
  更小都不提示，只有严格更大才提示；tag 无法解析成 `<name>+<build>` 形式时
  （例如老式无 build number 的 tag）才退回时间戳兜底比较，且在代码注释和
  测试里都明确标注这是兼容性 fallback，不是主路径。
- ABI → APK 资产匹配新增 `pickAndroidApkAsset()`：要求文件名同时"包含 ABI
  字符串"且"以 `.apk` 结尾"，避免误选 `SHA256SUMS.txt` / `*.apk.sha256` /
  `*.json` 等非 APK 文件；按 `supportedAbis` 顺序找第一个匹配项，找不到时
  由 `Update.onDownload()` 回退打开 Release 的 `html_url`
  （缺失时再退到 `releases/latest` 页面）。
- 更新弹窗内容扩充：Release tag、名称、发布说明（body）、发布时间、
  当前安装版本、新版本号，「下载更新」/「查看 Release」/「取消」三个按钮，
  自动检查场景保留「不再提醒」。不再链接到 `commits/main`（改为直接链接
  Release 页面，信息更完整）。
- 以上纯逻辑部分（tag/版本解析、Release JSON 解析、更新判断、ABI 资产匹配）
  全部抽成不依赖 Flutter UI/网络/全局状态的纯函数，新增 46 条离线单测
  （`test/utils/update/release_update_logic_test.dart`），覆盖任务要求的
  全部场景：build number 大于/等于/小于当前版本、tag 带/不带 `v`、无效/空
  tag、极大 build number、versionName 变化但 build number 不变、
  created_at 变化但版本不变、本地构建时间晚于 Release 但 Release 版本更高
  仍应提示、正常/404/空/错误/缺 tag/缺 assets/draft/prerelease 的 Release
  响应、精确 ABI 匹配、大小写差异、多个 APK、只有 checksum、无匹配回退、
  第二 ABI 命中、不误选 `.sha256`/`.json`。

**GitHub Actions 发布工作流重构**（`.github/workflows/build.yml` +
新增 `lib/scripts/release_version.ps1`）：

- Android job 的 PR 触发条件从"仅上游仓库"改为本仓库的 PR 都可以跑编译
  验证；PR 构建结构性地不接触任何 release 签名 secret（`IS_RELEASE` 恒为
  `false`，写 keystore 的步骤在 `IS_RELEASE == 'true'` 时才运行）。
- `workflow_dispatch` 默认值改为只勾 `build_android`（其余四个平台默认
  `false`），避免误触发全平台构建；`tag` 输入非空即视为正式发布。
- 新增正式发布 preflight（任一失败都让 workflow 失败、不创建 Release、
  不退回 debug 签名）：
  1. 校验只能来自 `workflow_dispatch`（非 PR）。
  2. 校验 `SIGN_KEYSTORE_BASE64`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/
     `KEY_PASSWORD` 四个 secret 都非空。
  3. 新增 `lib/scripts/release_version.ps1`：校验 tag 格式合法、且与
     `pubspec.yaml` 当前 `version:` 字段的 `<name>+<build>` 完全一致
     （不一致直接失败，不使用两套互相冲突的版本来源——正式发布只认
     `pubspec.yaml`，不再像 `lib/scripts/build.ps1` 那样用
     `git rev-list --count HEAD` 现算 build number；`build.ps1` 保持
     不变，继续只用于 PR/测试构建）。
  4. 用 `gh release view` 校验该 tag 尚未存在，禁止覆盖已发布的正式版本。
- APK 构建后新增 `apksigner verify --verbose --print-certs` 签名校验，
  失败即让 workflow 失败（不会发布未经验证签名的 APK）；新增
  `SHA256SUMS.txt` 并随 APK 一起上传到 Release；新增 job summary，输出
  commit/分支/versionName/versionCode/tag/签名类型/是否创建了 Release/
  每个 APK 的文件名+大小+SHA-256，明确不输出 keystore Base64、密码或
  证书私钥内容。
- Release 创建改用 `target_commitish: ${{ github.sha }}`（固定到本次
  workflow 实际构建的 commit）、`generate_release_notes: true`、
  `draft: false`、`prerelease: false`、`fail_on_unmatched_files: true`；
  job 权限从 `write-all` 收紧到 `contents: write`。
- 测试构建（`workflow_dispatch` 但 tag 留空）使用 `.dev` applicationId、
  文件名带 `PiliPlus_android_dev_` 前缀、只上传 Actions artifact、不创建
  Release，job summary 会明确标注 "dev/debug" 签名，与正式发布包（
  `com.example.piliplus`，release keystore 签名）在 applicationId 和签名
  上都不同，可以同时安装、不会互相覆盖，也不会被 App 的更新检查发现。
- `ios`/`mac`/`win_x64`/`linux_x64` 四个平台 job **未改动核心逻辑**
  （本轮范围限定在 Android），只是继承了 `workflow_dispatch` 默认值的
  调整（默认不再自动构建）。

**签名安全**：

- `.gitignore` 补充 `**/android/app/key.jks`、`*.keystore`
  （原有 `**/android/key.properties`、`*.jks` 保留）；确认改动前后都没有
  任何 keystore/key.properties 文件被 Git 跟踪。
- 新增 [`docs/RELEASE_GUIDE.md`](../docs/RELEASE_GUIDE.md)：中文、面向不
  熟悉 GitHub Actions 的个人维护者，说明如何本地生成 release keystore、
  转 Base64 配置 4 个 GitHub Secrets（并提醒配置完删除明文 Base64 文件、
  密钥不得上传仓库/不得发给 Agent）、旧签名不兼容时的表现与
  `apksigner verify` 排查方法、完整正式发版步骤、测试构建与正式发布的
  区别。

**尚未执行、需要用户后续操作**：

- 仓库尚未配置 `SIGN_KEYSTORE_BASE64`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/
  `KEY_PASSWORD` 这 4 个 GitHub Secrets。
- 尚未触发过一次正式发布（`ArthurADDDDD/PiliPlus` 目前仍是 0 个 Release）。
- 本轮未合并到 `main`，未创建任何 tag，未触发任何 GitHub Actions，未创建
  任何 Release，未上传任何 APK。
- 检查更新弹窗、下载、覆盖安装、旧签名兼容性等**全部未在真机上验证过**。
- workflow YAML 本轮只做了人工静态检查 + PyYAML 语法解析（沙箱环境没有
  `actionlint`，按任务要求不为此扩大范围去安装），未经过 GitHub 真实
  跑一次 workflow 的端到端验证。

## 2026-07-10（第十轮）

### 应用内检查更新改为指向本 fork（代码完成，待发布 Release 才生效）

- `lib/utils/update.dart` 的检查更新机制此前硬编码指向上游
  `bggRGjQaUbCoE/PiliPlus` 的 GitHub Releases API 与源码链接——本 fork
  用户会被提示"发现新版本"却下载到上游的、applicationId/签名/功能都不同
  的安装包。已把 `Api.latestApp`（`lib/http/api.dart`）与
  `Constants.sourceCodeUrl`（`lib/common/constants.dart`）改为指向
  `ArthurADDDDD/PiliPlus`。
- 机制本身不变：启动时（`自动检测更新` 开启时）与「关于」页手动检查都会
  拉取 `GET /repos/ArthurADDDDD/PiliPlus/releases`，用
  `BuildConfig.buildTime`（构建时 `--dart-define=pili.time=<epoch>` 注入）
  与最新 Release 的 `created_at` 比较，弹窗内按平台/架构名匹配 Release
  assets 提供下载。
- **尚未生效**：通过 GitHub API 确认 `ArthurADDDDD/PiliPlus` 目前**没有
  任何 GitHub Release**（仓库现在的发布方式是把 APK 直接提交进
  `release/` 目录，不是 GitHub Release）。检查更新会请求成功但返回空列表，
  不会报错也不会弹窗提示新版本。要让该功能真正生效，需要：
  1. 在这个 fork 上发布至少一个 GitHub Release（可以手动创建并上传 APK，
     也可以用仓库已有的 `.github/workflows/build.yml`
     的 `workflow_dispatch` 触发，带 `tag` 输入时会自动创建 Release 并
     上传按 `PiliPlus_android_<version>_<abi>.apk` 命名的 assets——文件名
     里的架构字符串如 `arm64-v8a` 正是 `onDownload()` 用来匹配的关键字，
     无需改代码即可工作）。
  2. 若要正式签名（而非默认 debug 签名）的 Release APK，还需要在这个
     fork 仓库的 Settings → Secrets 配置 `SIGN_KEYSTORE_BASE64` /
     `KEYSTORE_PASSWORD` / `KEY_ALIAS` / `KEY_PASSWORD`。
  3. 之后本地手动构建（未走 CI、未传 `--dart-define=pili.time=...` 等）的
     APK，`BuildConfig.buildTime` 会是默认值 `0`，检查更新时会一直认为
     "有新版本"——这属已知的、独立于本次改动的行为，只影响手动构建的包，
     不影响通过 workflow 构建、正确注入了 `pili.time` 等 define 的包。
- 本轮未触发任何 GitHub Actions workflow、未创建 Release（这些是有外部
  可见影响的操作，需要用户另行决定并执行/授权）。

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

