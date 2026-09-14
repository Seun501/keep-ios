# Keep · iOS

克的家的 iOS 端（原生 SwiftUI）＋手表端。仓库公开（`Seun501/keep-ios`，公开仓的 Actions 分钟不限量），**仓里永远不能有密钥**：密钥只在 GitHub Secrets 与本地 `密钥与登录\`。没有 Mac：造工程、编译、签名、上传全在 GitHub 的 macOS 打包机上跑；本地没有 Swift 工具链，改完只能推上去看班次结果。

## 现在是什么样（2026-09-14）

- **原生为主**：聊天流（克的思考链、工具行、末尾 `[reply: …]` 摘成输入卡上方的选项卡、她点的那句标序号）、输入卡、抽屉（书架/相册/留言板/记忆/位置、月历、额度）、留言板与信、档案馆、相册、记忆、常去的地方（地理围栏，定位「始终」）、书架、开屏问候。网页壳 `WebShellController` 只剩深链兜底。
- **健康**：读健康库直推网关 `/api/health/push`（起床档＋当下快照；网关静默推送能把 App 叫醒再读一份）。紫外线读 Apple 天气（`UVToday`，WeatherKit），随快照带给网关；抽屉底部有 Apple Weather 署名（使用条款要求）。
- **推送**：APNs（`PushRegistrar`），克的 knock、网关告警、晨间紫外线走它。
- **手表端** `Watch/`：腕上健康中继——表自己读健康库自己推（不等手机解锁），睡眠写库那刻补推；登录票由手机经 WatchConnectivity 传去，表上不登录。
- **形态**：iOS 16.4+、只做 iPhone、竖屏；watchOS 10+。寻的手机 iPhone 11 / iOS 26，无灵动岛不做；验收以真机为准。
- **口味**（寻定）：不描边、无阴影、忌浓艳大色块；淡水色底＋同系深字；卡片高度不随内容变；Lucide 线性图标；克的字 Lora＋思源宋，界面字母数字 Cascadia Mono；页面切换不淡入淡出、不从下冒出。

## 工程文件

- `project.yml`（XcodeGen）：打包机上现造 `.xcodeproj`，仓里不存工程文件。显式 `Info.plist`（自动生成会丢 `UIBackgroundModes`，踩坑册 00 章）。权限文案、能力（HealthKit / WeatherKit / 推送）、字体都在这一份里。
- `Sources/` 手机端，`Watch/Sources/` 手表端，`Resources/` 图标、字体、Clawd 小人、`preview_*.json`（预览模式假数据，截图班用）。
- 套装 ID `cn.seunk.keep`；App Store Connect 登记名 **Kaep**（Keep 被占），桌面名 Keep。

## 打包机两班（`.github/workflows/ios.yml`）

| 班 | 触发 | 干什么 | 看哪 |
|---|---|---|---|
| build（截图班） | 推 `main` 且改了 `Sources/Resources/project.yml`；或 `gh workflow run iOS -f screens="chat drawer"` | 编模拟器版（不签名），预览模式起 App、每页截一张 | Actions 产物 `sim-<run号>` |
| testflight | `gh workflow run iOS -f testflight=true`（或推 `v*` 标签） | 真机归档、手动签名、直传 TestFlight | TestFlight 里的新构建 |

- 构建号＝Actions run 号。一次截图班约 5 分半（`screens` 只点名要看的页），testflight 约 2 分半。
- Apple 每日 TestFlight 上传有上限（一天两三包）：改动攒成一包再出。
- 同一分支上新班次会取消进行中的旧班次（`concurrency`）：推完立刻派 testflight 会把截图班掐掉，要截图就等它跑完再派。

## 签名与密钥（已办）

手动签名：用 App Store Connect API 申请的 Apple Distribution 证书＋App Store 描述文件（手机 `Keep AppStore`、手表各一份），到期 **2027-09-02**；原件在 `密钥与登录\ios-signing\`，仓库密钥见 `ios.yml` 里「落 App Store Connect 密钥」「装签名证书与描述文件」两步用到的名字。到期或换证书重跑申请脚本（CSR → `POST /v1/certificates` → `POST /v1/profiles`）。APNs 密钥在服务器 `.env`（`APNS_*`），仓里没有。Apple ID 密码不上任何服务器。

## 心愿单（寻提的，未排期）

- **语音条**：录一段发给克，气泡可点开听；服务器先转文字给克看并标明是语音条。寻在找参考教程（09-14）。
- 地图栏去留；Watch 表盘复杂功能二期。

## 踩坑册

`https://github.com/Cheiineeey/ios-app-where-it-breaks`——签名、来电界面、推送、健康权限的真机踩坑记录。要点：报错文字常指错方向，查 `codesign -d --entitlements -` 与 `plutil -p Info.plist` 看包里实况；VoIP 推送与普通推送是两套令牌。
