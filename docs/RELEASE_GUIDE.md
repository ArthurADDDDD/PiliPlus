# PiliPlus Fork 发布指南

面向不熟悉 GitHub Actions 的个人维护者，说明如何给
[`ArthurADDDDD/PiliPlus`](https://github.com/ArthurADDDDD/PiliPlus) 发布正式版本，
让已安装的 App 能通过内置的检查更新自动发现新版本。

配套阅读：[`docs/POWER_TEST_GUIDE.md`](POWER_TEST_GUIDE.md)（功耗测试，与发布无关）、
[`AGENT_HANDOFF.md`](../AGENT_HANDOFF.md)、[`UPDATE.md`](../UPDATE.md)。

## 目录

1. [首次配置固定签名](#1-首次配置固定签名)
2. [旧 APK 签名兼容](#2-旧-apk-签名兼容)
3. [每次正式发版流程](#3-每次正式发版流程)
4. [测试构建流程](#4-测试构建流程)
5. [App 更新检查的判断规则](#5-app-更新检查的判断规则)

---

## 1. 首次配置固定签名

Android 应用必须用**同一把签名证书**才能覆盖安装旧版本。这把证书只需要生成**一次**，
之后所有正式 Release 都必须永久复用同一把——换了证书，用户就再也无法直接覆盖升级，
只能卸载重装（丢失本地数据）。

### 1.1 生成 release keystore（仅本地执行一次）

在你自己的电脑上执行（**不要在 CI、不要在任何 Agent 会话里执行**，密钥必须只留在你自己手上）：

```powershell
keytool -genkeypair -v `
  -keystore piliplus-release.jks `
  -alias piliplus `
  -keyalg RSA `
  -keysize 4096 `
  -validity 10000
```

执行时会要求你设置：

- keystore 密码（`storePassword`）
- 密钥密码（`keyPassword`，可以和 keystore 密码相同）
- 证书信息（姓名、组织等，随便填，不影响功能）

生成后会得到一个 `piliplus-release.jks` 文件。

**必须牢记：**

- keystore 文件和两个密码必须**长期妥善保存**，建议至少保留 **两份离线备份**
  （例如一份放加密 U 盘，一份放密码管理器的附件功能）。
- **丢失 keystore 或密码后，将永远无法再对已安装的正式版本发布可覆盖升级的新版本**——
  只能让用户卸载旧版重装新版本，且会丢失本地数据（观看历史、设置等）。
- **不得**把 `.jks` 文件提交进 Git 仓库（`.gitignore` 已经忽略 `*.jks` / `*.keystore` /
  `android/key.properties`）。
- **不得**把 keystore 文件或密码发给任何 AI Agent（包括 Claude）、粘贴进聊天记录，
  或上传到任何第三方服务。它只应该存在于：你自己的本地磁盘/备份介质，以及下面第 1.2
  步配置的 GitHub Actions Secrets（GitHub 只允许写入不允许读出）。

### 1.2 转成 Base64，写入 GitHub Secrets

Windows PowerShell 里把 keystore 转成 Base64 文本：

```powershell
[Convert]::ToBase64String(
  [IO.File]::ReadAllBytes("piliplus-release.jks")
) | Set-Content -NoNewline "keystore-base64.txt"
```

打开 `keystore-base64.txt`，全选复制里面的内容。

然后在浏览器打开：

```
https://github.com/ArthurADDDDD/PiliPlus/settings/secrets/actions
```

点击 "New repository secret"，依次新建 4 个 secret：

| Secret 名称 | 内容 |
|---|---|
| `SIGN_KEYSTORE_BASE64` | 上面复制的 Base64 文本（整个 `keystore-base64.txt` 的内容） |
| `KEYSTORE_PASSWORD` | 第 1.1 步设置的 keystore 密码 |
| `KEY_ALIAS` | 第 1.1 步 `-alias` 的值，示例中是 `piliplus` |
| `KEY_PASSWORD` | 第 1.1 步设置的密钥密码 |

**配置完成后，立刻删除 `keystore-base64.txt` 这个明文文件**（`Remove-Item
keystore-base64.txt`），不要把它留在磁盘上，更不要提交进任何仓库。

4 个 secret 都配置好之后，正式发布 workflow 才能跑通；缺任何一个都会在
[preflight 阶段](#3-每次正式发版流程) 直接失败，不会用临时签名蒙混过关。

---

## 2. 旧 APK 签名兼容

- Android 系统只有在**新旧 APK 的 `applicationId` 和签名证书完全一致**时才允许覆盖安装。
  `applicationId` 本 fork 固定为 `com.example.piliplus`，不会改变；签名证书就是第 1 节
  生成的那把 release keystore。
- `adb install -r -d` **无法绕过**签名不一致的限制——这是 Android 系统层面的强制校验，
  任何安装方式都绕不过去。
- 如果你手机上**当前安装的版本**是用另一把 debug/release key 签名的（比如之前手动
  `flutter build apk` 生成、没配置过 `key.properties` 的版本，那种默认用的是
  Gradle 自带的 debug key），你需要找到*那一把*旧密钥继续用来签名，否则无法覆盖安装。
- 如果找不到旧密钥，**唯一的办法**是先卸载旧版本再安装新签名的版本——这会清空
  本地 App 数据（观看历史、下载记录、账号登录状态等，取决于你是否开启了云端同步）。
- 因此，**你第一次用第 1 节流程建立自己的固定 release keystore 之后，
  之后每一次正式发布都必须永久复用这同一把 keystore**，不能换。

如果想确认某个 APK 文件的签名证书，可以用（Android SDK 自带的 `apksigner`）：

```powershell
apksigner verify --verbose --print-certs ".\PiliPlus.apk"
```

输出里的 "Signer #1 certificate SHA-256 digest" 就是这把证书的指纹；对比两个 APK
这一行是否一致，就能判断它们是不是同一把签名。

**本指南和相关 Agent 会话本轮都不会在你的设备上运行 `adb`**，上面的命令仅供你自己
在需要时手动执行参考。

---

## 3. 每次正式发版流程

1. 确认要发布的改动已经合并到 `main` 分支。
2. 修改并提交 `pubspec.yaml` 的 `version:` 字段，格式是 `<versionName>+<buildNumber>`，
   例如：

   ```yaml
   version: 2.0.9+5103
   ```

   `buildNumber`（`+` 后面的整数）必须比上一个正式版本大——App 内的更新检查**只**
   看这个数字判断是否有新版本，不看时间、不看版本名文字。建议每次发布让它单调递增
   （比如上次是 5103，这次用 5104），不要求任何固定步长。

3. 确保接下来要填的 Release tag 与这个版本号完全一致，格式为 `v<versionName>+<buildNumber>`：

   ```
   v2.0.9+5103
   ```

   （`v` 前缀可写可不写，两种 CI 都认；但两处的 `versionName+buildNumber` 部分必须
   逐字一致，否则 CI 会在 preflight 阶段直接失败，不会发布出去。）

4. 提交 pubspec.yaml 的改动，push 到 `main`。

5. 打开：

   ```
   GitHub → 仓库主页 → Actions → 左侧选择 "Build" → 右上角 "Run workflow"
   ```

6. 在弹出的表单里填：

   - **Use workflow from**：`Branch: main`
   - **Build Android**：保持勾选（默认就是 `true`）
   - **Build iOS / Build Mac / Build Win-x64 / Build Linux-x64**：保持不勾选
     （默认都是 `false`，避免每次误触发全平台构建）
   - **tag**：填入第 3 步确定的 tag，例如 `v2.0.9+5103`

   点击绿色的 "Run workflow" 按钮。

7. 等待 workflow 跑完（Android 编译 + preflight 校验 + 签名 + Release 创建，
   一般几分钟到十几分钟）。如果 preflight 任何一项没通过（密钥没配、tag 和
   pubspec.yaml 版本对不上、tag 已经存在过），workflow 会直接失败并在日志里
   写清楚原因——**这种情况下不会创建 Release、不会发布任何 APK**，按提示修正后
   重新触发即可。

8. workflow 成功后，打开仓库的 Releases 页面确认：

   ```
   https://github.com/ArthurADDDDD/PiliPlus/releases
   ```

   - 新 Release（tag 就是你填的那个）已经出现；
   - Release 里附带 `PiliPlus_android_<版本>_arm64-v8a.apk`
     （Pixel 10 Pro 用这个）、`..._armeabi-v7a.apk`、`..._x86_64.apk`；
   - `SHA256SUMS.txt` 也在附件里；
   - 打开这次 workflow 运行的 "Summary" 页面，确认 "signing" 一栏写的是
     "release keystore"（不是 "dev/debug"），"formal release created" 是 "true"。

9. 已经安装 fork 版 PiliPlus 的手机，会在下一次自动检查更新时（或用户手动点
   「关于」页的检查更新）看到弹窗提示。

10. 用户点「下载更新」，App 会按手机的 CPU 架构自动打开对应的
    `arm64-v8a`/`armeabi-v7a`/`x86_64` APK 下载链接（Pixel 10 Pro 对应
    `arm64-v8a`）；没有精确匹配架构的资产时会退回打开这次 Release 的页面。

11. Android 的安装确认界面由用户自己手动点「安装」/「更新」完成，
    **App 内不会自动下载、不会自动安装**。

---

## 4. 测试构建流程

如果只是想验证代码能编译通过、或者想要一个能装到自己测试机上看效果的临时包，
**不要**在触发 workflow 时填 tag：

- 把上面第 3 节步骤 6 的 "tag" 输入框留空，直接 "Run workflow"。
- 这种情况下只会生成一个 GitHub Actions **artifact**（工作流运行页面下方可以下载），
  **不会**创建任何 GitHub Release。
- 因为不创建 Release，**已安装用户的 App 更新检查永远不会发现这个测试包**
  （检查更新只看 `/releases/latest`，Actions artifact 不在这个 API 范围内）。
- 测试包用 `.dev` applicationId（`com.example.piliplus.dev`），文件名带
  `PiliPlus_android_dev_` 前缀，与正式包（`com.example.piliplus`）可以同时装在
  同一台设备上，互不冲突、互不覆盖。
- 测试包目前用 Gradle 默认 debug 签名，不是第 1 节配置的正式 release keystore——
  它和正式发布包是两个完全不同签名的应用，不能互相覆盖安装。
- 简单说：**Actions artifact ≠ GitHub Release asset**，两者是完全不同的概念，
  测试包也不等于正式发布包，不要混为一谈。

拉取请求（PR）触发的构建同样只是编译验证 + artifact，逻辑一致，额外不会读取任何
release 签名 secret（PR 场景下 `SIGN_KEYSTORE_BASE64` 等变量对 workflow 不可见）。

---

## 5. App 更新检查的判断规则

供排查问题参考，App 侧代码见 `lib/utils/update.dart` 与
`lib/utils/update/release_update_logic.dart`：

- 只请求 `GET /repos/ArthurADDDDD/PiliPlus/releases/latest`（单个最新正式 Release，
  不是列表，天然排除 draft，GitHub 也不会在这个接口返回 prerelease 除非专门放开）。
- 判断是否有新版本：**只看 Release tag 里的 build number**（`v2.0.9+5103` 里的
  `5103`）是否比当前安装版本的 build number 大。不看 Release 创建时间、不看
  版本名文字、不看正文改动。
  - 编辑 Release 文案、或删除重建同一个 tag，都不会导致重复弹窗（tag/build
    number 没变）。
  - 只有当 tag 不符合 `[v]<name>+<数字>` 格式时（比如老版本遗留的 `v2.0.9`
    这种没有 build number 的 tag），才会退回用发布时间和本地构建时间比较——
    这是明确标注的兼容性兜底，不是主要判断依据。
- 仓库还没有发布任何 Release 时（GitHub 返回 404），App 静默不提示（自动检查）
  或明确提示"当前仓库还没有发布正式版本"（手动检查）——不会被误当成程序错误。
- Android 下载会按 `supportedAbis` 顺序找文件名同时满足"包含该 ABI 字符串"且
  "以 `.apk` 结尾" 的资产，避免误选 `SHA256SUMS.txt` 或 `.apk.sha256` 校验文件；
  找不到匹配 APK 时会打开 Release 页面，而不是静默失败。

**本指南本身不构成"已完成实机验证"的证明**——文档写好之后，仍然需要：

- 真正配置好第 1 节的 4 个 GitHub Secrets；
- 真正触发一次第 3 节的正式发布流程；
- 真正在一台已安装旧版 fork 应用的手机上，验证检查更新弹窗、下载、安装升级的
  完整链路都符合预期。

这些都是本文档发布时**尚未执行**的步骤，需要用户后续自行完成。
