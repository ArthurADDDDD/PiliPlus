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
5. [版本兼容说明](#5-版本兼容说明)
6. [App 更新检查的判断规则](#6-app-更新检查的判断规则)

---

## 1. 首次配置固定签名

Android 应用只有在**新旧 APK 的 `applicationId` 和签名证书完全一致**时才允许覆盖安装
（详见 [第 2 节](#2-旧-apk-签名兼容)）。这把签名证书只需要确定**一次**，之后所有正式
Release 都必须永久复用同一把——换了证书，用户就再也无法直接覆盖升级，只能卸载重装
（丢失本地数据）。

有两种方案，二选一：

- **方案 A（推荐）：沿用你手机上现有 APK 已经在用的签名**，免卸载迁移，保留现有数据。
- **方案 B：新建一把专用 release key**，更「标准」，但首次发布无法覆盖现有安装，
  必须先卸载旧版才能装新签名版本。

### 1.1 方案 A（推荐）：沿用现有签名，免卸载迁移

如果你已经通过本地审计确认了当前手机上安装的 APK 使用的签名证书、以及对应密钥文件
在本地磁盘的位置（例如某次本地审计确认为
`storeFile: C:\Users\<你的用户名>\.android\debug.keystore`、`alias:
androiddebugkey`），可以直接把**这一把**密钥配置成 GitHub Actions 用来签正式 Release
的密钥，不需要重新生成。

Android 判断"能否覆盖安装"只看**证书**是否一致，不看文件名或密钥别名叫什么——即使
这把密钥的文件名和别名带有 "debug" 字样，只要 GitHub Actions 用同一个 keystore 文件
和同一个 alias 去签名，产出的 APK 证书就和你现在手机上装的这版完全一致，可以正常
覆盖升级。

**必须明确的风险（写清楚，不隐瞒）：**

- 这类密钥通常使用较弱或默认的密码，安全性主要依赖 keystore 文件本身不泄漏，而不是
  密码强度本身。
- 一旦这个 keystore 文件丢失或泄漏，长期发布链路会受影响（丢失=以后无法再发能覆盖
  升级的新版本；泄漏=别人理论上能签出证书相同、能冒充覆盖安装到你设备上的 APK）。
- 这**不适合**作为大规模公共商业发行的理想签名方案——但本项目是你个人维护、个人使用
  的 fork，不对公众分发，因此该风险可以接受，前提是把风险写清楚（就是本节在做的事）。

只要接受以上风险，方案 A 的好处很直接：**不需要因为换签名而卸载现有 App**、
**可以保留当前应用数据**、**GitHub Release APK 能继续覆盖安装**、
**后续自动更新链路能够保持一致**。

#### 1.1.1 备份现有密钥（不要移动/删除原文件）

在你自己的电脑上执行（**不要在 CI、不要在任何 Agent 会话里执行**——密钥文件本身不
会、也不应该提供给任何云端 Agent 环境，包括本次会话）：

```powershell
New-Item -ItemType Directory -Force "D:\PiliPlus-Signing-Backup"

Copy-Item `
  "$env:USERPROFILE\.android\debug.keystore" `
  "D:\PiliPlus-Signing-Backup\piliplus-signing.jks"
```

再手动复制一份到另一个离线介质（U 盘、移动硬盘等），凑够至少两份离线备份。

**必须牢记：**

- 上面这条命令只是**复制**，原文件 `%USERPROFILE%\.android\debug.keystore`
  **不会被删除、也不应该被删除**——它是 Android 开发工具链自己会用到的标准位置，
  继续留在那里不影响本地开发，也是这把密钥现存的"最初"副本之一。
- 复制、改名（示例改成了更好辨认的 `piliplus-signing.jks`）**不会改变证书**，
  不需要也不应该用这把密钥重新执行 `keytool -genkeypair` 之类会生成新密钥的命令。
- 这个文件和它对应的密码必须**长期妥善保存**：至少两份离线备份，丢失后将永远无法
  再对已安装的正式版本发布可覆盖升级的新版本，只能让用户卸载旧版重装（丢失本地数据）。
- **不得**把 `.jks`/`.keystore` 文件提交进 Git 仓库（`.gitignore` 已忽略
  `*.jks`/`*.keystore`/`android/key.properties`/`android/app/key.jks`）。
- **不得**把这个文件或它的密码粘贴进聊天记录、Issue、或发给任何 AI Agent
  （包括 Claude）——它只应该存在于：你自己的本地磁盘/备份介质，以及下面
  [1.3 节](#13-配置-github-secrets-和-签名证书指纹锁定) 配置的 GitHub Actions Secrets
  （GitHub 只允许写入、不允许读出）。

#### 1.1.2 确认证书（可选，进一步核实）

如果想再次确认这把密钥对应的证书信息（本地执行，输出仅供你自己核对）：

```powershell
keytool -list -v `
  -keystore "D:\PiliPlus-Signing-Backup\piliplus-signing.jks" `
  -alias androiddebugkey
```

系统会提示输入密码——请填写你自己本地审计已经确认可用的实际密码（本文档不写死、
也不需要知道具体密码值）。输出里 "Certificate fingerprints" 下的 "SHA256" 那一行，
就是这把证书的指纹，[1.3 节](#13-配置-github-secrets-和-签名证书指纹锁定) 会用到。

跳到 [1.3 节](#13-配置-github-secrets-和-签名证书指纹锁定) 继续，不需要看 1.2。

### 1.2 方案 B：新建专用 release key

如果不想沿用现有密钥（例如担心方案 A 的风险、或者以后想更规范地管理签名），可以走
这条路，但要清楚代价：

- 会产生**不同的证书**，因此新签的 Release **不能覆盖**当前 debug 签名的版本。
- 第一次发布新签名版本时，**必须先卸载手机上的旧版**才能安装。
- 卸载会**丢失本地数据**（观看历史、下载记录、账号登录状态等，取决于是否开了云同步）。
- 从新密钥发布的第一个版本开始，**以后必须永久复用这把新密钥**（否则又会重演一次
  这里描述的迁移问题）。

生成命令（本地执行，仅供需要方案 B 时参考，**不要用真实密钥信息在此演示**）：

```powershell
keytool -genkeypair -v `
  -keystore piliplus-release.jks `
  -alias piliplus `
  -keyalg RSA `
  -keysize 4096 `
  -validity 10000
```

生成后同样需要按 [1.1.1](#111-备份现有密钥不要移动删除原文件) 的方式做好离线备份，
其余步骤（转 Base64、配置 Secrets、配置指纹锁定）与方案 A 完全一样，见下面 1.3 节。

**对于当前用户，推荐方案 A**——目标是保留现有安装和数据，方案 A 能免卸载迁移，
方案 B 则必须先卸载一次。

### 1.3 配置 GitHub Secrets 和 签名证书指纹锁定

不管选方案 A 还是方案 B，最终都要在 GitHub 仓库配置同一组 Secrets/Variable，
以下步骤统一适用（示例路径按方案 A 的 `D:\PiliPlus-Signing-Backup\piliplus-signing.jks`
来写，方案 B 换成你自己 keystore 的实际路径）。

#### 1.3.1 转成 Base64

Windows PowerShell 里把 keystore 转成 Base64 文本：

```powershell
[Convert]::ToBase64String(
  [IO.File]::ReadAllBytes(
    "D:\PiliPlus-Signing-Backup\piliplus-signing.jks"
  )
) | Set-Content -NoNewline "D:\PiliPlus-Signing-Backup\keystore-base64.txt"
```

打开 `keystore-base64.txt`，全选复制里面的内容。

#### 1.3.2 配置 4 个 GitHub Secrets

浏览器打开：

```
https://github.com/ArthurADDDDD/PiliPlus/settings/secrets/actions
```

点击 "New repository secret"，依次新建 4 个 secret：

| Secret 名称 | 内容 |
|---|---|
| `SIGN_KEYSTORE_BASE64` | 上一步复制的 Base64 文本（整个 `keystore-base64.txt` 的内容） |
| `KEYSTORE_PASSWORD` | 这把 keystore 的密码（本地审计已确认可用的实际值，本文档不写死） |
| `KEY_ALIAS` | 密钥别名——方案 A 示例中是 `androiddebugkey`，方案 B 是你 `-alias` 用的值 |
| `KEY_PASSWORD` | 密钥密码（同上，实际值以本地审计/生成时设置的为准） |

**配置完成后，立刻删除 `keystore-base64.txt` 这个明文文件**（`Remove-Item
"D:\PiliPlus-Signing-Backup\keystore-base64.txt"`），不要把它留在磁盘上，
更不要提交进任何仓库。**但不要删除** `piliplus-signing.jks` 本身——那是你唯一
能重新生成 Base64/重新签名的来源。

#### 1.3.3 配置 EXPECTED_SIGNING_CERT_SHA256（证书指纹锁定，防误传）

这一步是防呆机制：如果哪天不小心在 `SIGN_KEYSTORE_BASE64` 里填错了另一把**有效但
不同**的 keystore（比如手滑传了方案 B 新生成的密钥，却以为在用方案 A 那把），
workflow 会在构建前和构建后**各自**校验一次实际用到的证书指纹，一旦跟预期不符就
直接失败，不会悄悄发布一个用户装不上的"正式" Release。

证书指纹本身**不是秘密**（公钥指纹是公开信息，任何拿到 APK 的人都能自己算出来），
所以这里用的是 GitHub 的 **Repository Variable**，不是 Secret：

```
https://github.com/ArthurADDDDD/PiliPlus/settings/variables/actions
```

点击 "New repository variable"：

| Variable 名称 | 值 |
|---|---|
| `EXPECTED_SIGNING_CERT_SHA256` | 这把签名证书的 SHA-256 指纹，去冒号/空格、大小写均可（workflow 会自动规范化） |

证书指纹不是密码、不需要保密。如果走的是方案 A（沿用现有签名），且这把密钥确实是
当前手机上安装版本用的那一把，本轮本地审计已经确认过它的指纹是：

```
2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349
```

（对应 alias `androiddebugkey`）——可以直接把这个值填进 `EXPECTED_SIGNING_CERT_SHA256`。
如果走方案 B，或者不确定这个值是否仍然准确，用 [1.1.2](#112-确认证书可选进一步核实)
的 `keytool -list -v` 命令，或 [第 2 节](#2-旧-apk-签名兼容) 的 `apksigner verify`
命令自己重新查一次为准。

配置好这 4 个 Secret + 1 个 Variable 之后，正式发布 workflow 才能跑通；缺任何一个、
或证书指纹对不上，都会在 [preflight 阶段](#3-每次正式发版流程) 直接失败，
不会用错误签名或临时 debug 签名蒙混过关。

---

## 2. 旧 APK 签名兼容

- Android 系统只有在**新旧 APK 的 `applicationId` 和签名证书完全一致**时才允许覆盖安装。
  `applicationId` 本 fork 正式包固定为 `com.example.piliplus`，不会改变；签名证书就是
  第 1 节配置的那把 keystore（方案 A 或方案 B 二选一，一旦选定就要永久复用）。
- `adb install -r -d` **无法绕过**签名不一致的限制——这是 Android 系统层面的强制校验，
  任何安装方式都绕不过去。
- 如果你手机上**当前安装的版本**是用另一把 debug/release key 签名的，你需要找到
  *那一把*旧密钥继续用来签名，否则无法覆盖安装。走方案 A（沿用现有签名）就是为了
  避免这个问题——只要密钥文件确实是当前安装版本用的那一把，签出来的证书就与手机上
  已装版本一致。
- 如果找不到旧密钥，**唯一的办法**是先卸载旧版本再安装新签名的版本——这会清空
  本地 App 数据（观看历史、下载记录、账号登录状态等，取决于你是否开启了云端同步）。
- 因此，**你第一次用第 1 节流程确定固定签名 keystore 之后，
  之后每一次正式发布都必须永久复用这同一把 keystore**，不能换。
- 为了防止以后不小心传错另一把有效但不同的 keystore，workflow 现在会在构建前后各
  校验一次实际证书指纹是否等于 [1.3.3 节](#133-配置-expected_signing_cert_sha256证书指纹锁定防误传)
  配置的 `EXPECTED_SIGNING_CERT_SHA256`，不一致直接失败，不会发布出一个装不上的
  "正式" Release。

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
   - Release 里只附带一个 APK：`PiliPlus_android_<版本>_arm64-v8a.apk`
     （本 fork 只维护 Pixel 10 Pro，不再构建/发布 `armeabi-v7a`、`x86_64`
     或通用 APK；如果这一步发现附件里出现了其他 ABI 或不止一个 APK，说明
     workflow 里 `--target-platform android-arm64` 的限制被破坏了，应视为
     构建失败处理，不要使用这次 Release）；
   - `SHA256SUMS.txt` 也在附件里；
   - 打开这次 workflow 运行的 "Summary" 页面，确认：
     - "signing" 一栏是 "release keystore"（不是 "dev/debug"）；
     - "formal release created" 是 "true"；
     - "expected signing cert SHA-256" / "keystore cert SHA-256" /
       "final APK cert SHA-256" 三行的值完全一致，"all three match" 是
       "true"——这三行不含密码，可以放心截图/分享给自己核对。

9. 已经安装 fork 版 PiliPlus 的手机，会在下一次自动检查更新时（或用户手动点
   「关于」页的检查更新）看到弹窗提示。

10. 用户点「下载更新」，App 会按手机的 CPU 架构在 Release 资产里找匹配的
    APK 下载链接（Pixel 10 Pro 对应 `arm64-v8a`，也是现在唯一会发布的
    架构）；没有精确匹配架构的资产时会退回打开这次 Release 的页面。

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
- 测试包和正式包一样，只构建 `arm64-v8a` 一个架构，只产出一个 APK 文件，
  作为单个文件（不是 zip 压缩包）上传成 Actions artifact，下载后可以直接
  安装。
- 测试包目前用 Gradle 默认 debug 签名，不是第 1 节配置的正式 release keystore——
  它和正式发布包是两个完全不同签名的应用，不能互相覆盖安装。
- 简单说：**Actions artifact ≠ GitHub Release asset**，两者是完全不同的概念，
  测试包也不等于正式发布包，不要混为一谈。

拉取请求（PR）触发的构建同样只是编译验证 + artifact，逻辑一致，额外不会读取任何
release 签名 secret（PR 场景下 `SIGN_KEYSTORE_BASE64` 等变量对 workflow 不可见）。

---

## 5. 版本兼容说明

本地一次审计确认过的当前安装 APK 信息：

```
Package: com.example.piliplus
Version name: 2.0.9
Version code: 1
```

据此，能顺利覆盖升级需要同时满足：

- 第一个正式 fork Release 的 `applicationId` 必须保持
  `com.example.piliplus`（不能是 `.dev` 后缀的测试包 applicationId——
  [第 4 节](#4-测试构建流程) 的测试 artifact 不能、也不该被用来覆盖正式包）。
- 新 APK 的 `versionCode` 必须**大于** `1`（当前安装版本的 versionCode）。
  本指南推荐的版本号规范 `<name>+<buildNumber>`（如 `2.0.9+5103`）里，`+`
  后面的 `5103` 就是 versionCode/build number，天然满足"大于 1"。
- 新旧 APK 使用相同的签名证书（见 [第 1](#1-首次配置固定签名)、
  [第 2 节](#2-旧-apk-签名兼容)）。

满足以上三条时，Android 系统层面可以正常执行覆盖升级。

**这里只是说明代码和签名条件已经满足覆盖升级的前提**，不代表已经在真机上验证过
覆盖安装成功——这仍然需要用户在完成 [第 1 节](#1-首次配置固定签名) 的密钥配置、
触发一次真实 Release 之后，自己在设备上手动安装验证一次。

---

## 6. App 更新检查的判断规则

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
