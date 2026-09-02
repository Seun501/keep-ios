# Keep · iOS

克的家的 iOS 端。仓库私有（GitHub `Seun501`），没有 Mac：打包、签名、上传全在 GitHub 的 macOS 打包机上跑。

## 现在是什么样（2026-09-02）

- **第一版＝原生壳**：`WKWebView` 全屏承载 `ke.seunk.cn`，键盘由原生接管（键盘升起时网页整块变矮，不再靠 visualViewport 猜）。User-Agent 带 `KeepShell/1`，网页可据此关掉自己那套键盘补丁。
- 路线＝**原生为主、分页搬迁**：聊天流/输入/推送先原生化，书架/档案/相册/记忆等长尾页暂留网页，之后逐页搬。
- 工程文件由 `project.yml`（XcodeGen）现造，仓库里没有 `.xcodeproj`。显式 `Info.plist`（自动生成会丢 `UIBackgroundModes`，踩坑册 00 章）。
- 套装 ID `cn.seunk.keep`，最低 iOS 16，只做 iPhone，竖屏。

## 打包机两班（`.github/workflows/ios.yml`）

| 班 | 触发 | 干什么 | 产物 |
|---|---|---|---|
| build | 推 `main` 且改了源码/配置 | 编模拟器版（不签名）、起模拟器截图 | Actions 页面「Artifacts」里的 `launch.png`、`Info.plist.txt` |
| testflight | 推 `v*` 标签，或 Actions 页手动勾「归档并上传 TestFlight」 | 真机归档、云签名、直传 TestFlight | TestFlight 里的新构建 |

私有仓库 macOS 分钟按 10 倍计（GitHub Free 每月 2000 分钟 ≈ 200 分钟 macOS）。一次 build 约 5–8 分钟，testflight 约 10–15 分钟。

## 寻要办的（一次性）

### ① GitHub
本机装了 `gh`。在 Claude Code 里输 `! gh auth login`，按提示选 GitHub.com → HTTPS → 浏览器登录。登完我建私有仓库并推代码。

### ② App Store Connect 密钥（testflight 班要用，build 班不用）
1. 打开 https://appstoreconnect.apple.com → **用户和访问** → **集成** → **App Store Connect API** → **团队密钥** → 生成。名字随意，访问权限选 **App 管理**。
2. 下载 `.p8`（**只能下一次**，丢了只能作废重生成）。放进 `密钥与登录\`（git 忽略），文件名形如 `AuthKey_XXXXXXXXXX.p8`，XXXXXXXXXX 就是 **Key ID**。
3. 同一页面顶部有 **Issuer ID**，抄下来。
4. **Team ID**：https://developer.apple.com/account → 会员资格详情 → 团队 ID（10 位）。
5. 把三个 ID 告诉我；`.p8` 我从 `密钥与登录\` 读、用 `gh secret set` 直接送进仓库密钥，不经终端回显、不进任何文档。

### ②′ 签名（已办，09-02）
自动签名要团队里至少登记一台设备才肯出描述文件；没线没 Mac，改**手动签名**：用 API 密钥直接申请了 Apple Distribution 证书与 App Store 描述文件 `Keep AppStore`（到期 2027-09-02），原件在 `密钥与登录\ios-signing\`（私钥/证书/p12 及口令/描述文件），仓库密钥 `DIST_P12_BASE64` / `DIST_P12_PASSWORD` / `APPSTORE_PROFILE_BASE64`。到期或换证书重跑申请脚本即可（脚本逻辑：CSR→POST /v1/certificates→POST /v1/profiles）。App Store Connect 登记名 **Kaep**（Keep 被运动软件占了；桌面显示名仍 Keep）。

### ④ APNs 推送密钥（构建 8 起 App 会登记令牌；没这把钥匙服务器发不出）
1. https://developer.apple.com/account/resources/authkeys → **+** → 名字随意（如 `Keep APNs`）→ 勾 **Apple Push Notifications service (APNs)** → Continue → Register → 下载 `.p8`（只能下一次）。
2. 把 `.p8` 放进 `密钥与登录\`，把文件名里的 Key ID（10 位）告诉我。Team ID 还是 `3QGZ67VKH7`。
3. 我把它传到服务器 `.env`（`APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_KEY_FILE` / `APNS_TOPIC`）并重启；之后克的 knock、网关告警会同时到 App 与网页。

### ③ App 记录（第一次上传前要有）
1. https://developer.apple.com/account/resources/identifiers → **+** → App IDs → App → Bundle ID 明确填 `cn.seunk.keep`，描述随意；Capabilities 勾 **Push Notifications**（以后要用）。
2. App Store Connect → **我的 App** → **+** → 新建 App：平台 iOS、名称 `Keep`（名字后面可改）、主要语言简体中文、套装 ID 选上一步那个、SKU 随意填 `keep`。
3. 第一次上传成功后：该 App → **TestFlight** → 内部测试 → **+** 建一个组、把自己加进去；手机装 **TestFlight** App，收到邮件即可装。

## 本地检查
没有 Swift 工具链，本地做不了编译；每次推代码看 Actions 的 build 班结果与截图。

## 踩坑册
`https://github.com/Cheiineeey/ios-app-where-it-breaks`——签名、来电界面（CallKit）、推送（APNs/VoIP）、健康权限的真机踩坑记录。要点：报错文字常指错方向，查 `codesign -d --entitlements -` 与 `plutil -p Info.plist` 看包里实况；来电界面必须在 VoIP 推送回调里**同步**上报，晚了会被系统永久吊销；VoIP 推送与普通推送是两套令牌。

## 心愿单（寻提的，未排期）
- **手表端**（寻的 Apple Watch 比手机新）：手表听写直接跟克说话；健康日内快照（总纲里归 watchOS 的那条）。
- **语音条**：录一段发给克，气泡可点开听；服务器先转文字给克看并标明是语音条。转文字引擎（腾讯机自跑开源模型 / 外部接口）到时候寻定。
