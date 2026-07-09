# PiliPlus · Pixel/Tensor 个人优化版

面向个人使用的 PiliPlus fork，主要在 Pixel 10 Pro / Android 17（API 37）/ Tensor 平台上做发热耗电优化、系统原生画中画、以及一些播放交互的打磨。保留 Bilibili 的完整日常体验，不做大规模阉割，SponsorBlock / 空降助手继续可用。

- **基于**：上游 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) `v2.0.9+1`（commit `90eee40f9` “flutter 3.44.5”）。
- **上游原版 README** 已归档到 [docs/archive/README.upstream.md](docs/archive/README.upstream.md)。
- **详细逐轮改动**见 [UPDATE.md](UPDATE.md)，待办与限制见 [TODO.md](TODO.md)。

## 相比上游改了什么

### 1. 返回键系统原生画中画（本 fork 核心）

按返回键让视频以**系统原生 PiP** 继续播放，同时回到 PiliPlus 的上一页——且不露出上一个 app。

- 单 `MainActivity` 无法让系统 PiP 盖在本 app 的上一页之上（PiP 是 Activity 级能力）。方案是新增独立的原生 **`PipActivity`** 作为 PiP 壳，把 libmpv 的视频输出 surface 从 Flutter 纹理**热切换**到壳的 `TextureView`——播放器不重建、不缓冲。
- Android 13+ 用 `ActivityOptions.makeLaunchIntoPip` 直接以 PiP 形态启动，无全屏闪现。
- PiP 为纯系统原生窗口：原生圆角、捏合缩放、拖动、关闭区，附带 快退10s / 播放暂停 / 快进10s 控件（经媒体会话）。
- 点展开 → 无缝回到视频页；拖到关闭区 → 停止播放、上报进度、销毁播放器。
- 为此把 `media_kit_video` 转为本地维护（`third_party/media_kit_video`，基于上游 fork `version_1.2.5`），新增 `externalSurfaceActive` 开关，PiP 接管期间挂起其自动重挂，避免输出被抢回 Flutter 纹理导致黑屏。
- 取舍：PiP 窗口内不显示弹幕（弹幕由 Flutter 渲染，无法进入原生窗口）。
- 备选：应用内浮动小窗（`返回时小窗播放`，默认关），带弹幕、可拖动吸边。

### 2. Android 17 / Tensor 省电

- 前台请求本应用 60Hz 渲染刷新率，降低发热与耗电（`Android 17/Tensor 省电刷新率`，API 37+ 默认开）。
- 调整 Android 默认播放负载：Wi-Fi 默认 1080P、蜂窝 720P，解码偏好 HEVC/AVC/AV1。
- 迁移路径默认关闭播放器预初始化与超分，但**保留**后台音频服务与高音质，不影响锁屏 / 后台 / PiP 听歌。

### 3. 新版滑动调节亮度/音量（默认）

- 旧版逐帧累加的亮度/音量调节稍滑就跳；新版改为「捕获手势起点值 + 相对起点总位移映射」，跟手不漂移。
- 亮度额外过一条 gamma(2.2) 感知曲线，暗处更细腻，接近原版 B 站丝滑手感。
- 旧逻辑保留为设置项 `使用旧版滑动调节`（默认关）。

### 4. 应用图标（可切换）

- 默认白色版 bilibili 图标（自适应 + 传统各尺寸）。
- 设置 `应用图标` 可在 `国际版 bilibili` / `原版 PiliPlus` 间切换
  （activity-alias + 运行时 PackageManager 切换组件）。

### 5. 「个性化改动」设置页

- 设置首项新增独立页 `个性化改动`，集中本 fork 新增的所有开关，
  避免散落在原版繁杂设置里。原版自带设置保持原位。

## 新增/变更设置

**播放设置**

- `返回键进入原生画中画`：默认开。返回键回上一页并以系统原生 PiP 继续播放。
- `返回时小窗播放`：默认关。上一项关闭时生效，改用应用内浮动小窗（带弹幕）。
- `后台画中画`：默认开。进入后台时以系统 PiP 播放。
- `关闭画中画时暂停`：默认开。PiP 拖到关闭区后停止播放。
- `画中画不加载弹幕`：默认关。
- `使用旧版滑动调节`：默认关。开启回到旧版逐帧亮度/音量调节。

**视频设置**

- `Android 17/Tensor 省电刷新率`：API 37+ 默认开，请求本应用 60Hz 渲染。

## 已知平台限制

- **PiP 默认大小/落点无法由 App 指定**：Android 不提供公开 API，系统自行决定并记忆用户上次拖动/缩放的结果（实测 `setSourceRectHint` 在 Pixel 上不改变落点）。
- **两种 PiP 记忆各自独立**：回桌面 PiP（`MainActivity`，带弹幕）与返回键 PiP（`PipActivity`，无弹幕）由系统按 Activity 组件分别记忆，无法用 API 合并；统一记忆需牺牲其中一种的弹幕，故保持现状。
- **微信分享仍为纯文字+链接**：原版卡片链接需微信开放平台 SDK + 绑定本包名/签名的 AppID，个人包无法获得，暂不实现（详见 [TODO.md](TODO.md)）。

## 当前 APK

- 实机验证：Pixel 10 Pro，Android 17 / API 37，arm64-v8a。
- 随仓库发布：[release/PiliPlus-arm64-v8a-release.apk](release/PiliPlus-arm64-v8a-release.apk)
- 最新 SHA256：`B7EE0035A102DD46B8A6AE03B17D381B9F9A1494B8ABBC294331C56AB6A636DC`
- 构建日期：2026-07-10

## 构建

依赖上游 fork 的自定义 `media_kit` 等（见 `pubspec.yaml` 的 git/path 依赖，`media_kit_video` 已 vendored 到 `third_party/`）。arm64 release：

```
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm64
```

本次开发使用的临时工具链（Flutter 3.44.5 / Android SDK / JDK 17 等）放在仓库外的 `D:\CodexTemp`，不提交。
