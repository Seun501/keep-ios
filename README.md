# Keep · iOS

克的家的 iOS 端（原生 SwiftUI）＋手表端。仓库公开（`Seun501/keep-ios`，公开仓的 Actions 分钟不限量），**仓里永远不能有密钥**：密钥只在 GitHub Secrets 与本地 `密钥与登录\`。没有 Mac：造工程、编译、签名、上传全在 GitHub 的 macOS 打包机上跑；本地没有 Swift 工具链，改完只能推上去看班次结果。

## 现在是什么样（2026-09-14）

- **原生为主**：聊天流（克的思考链、工具行、末尾 `[reply: …]` 摘成输入卡上方的选项卡、她点的那句标序号）、输入卡、抽屉（书架/相册/留言板/记忆/位置、月历、额度）、留言板与信、档案馆、相册、记忆、常去的地方（地理围栏，定位「始终」）、书架、开屏问候。网页壳 `WebShellController` 只剩深链兜底。
- **健康**：读健康库直推网关 `/api/health/push`（起床档＋当下快照；网关静默推送能把 App 叫醒再读一份）。紫外线读 Apple 天气（`UVToday`，WeatherKit），随快照带给网关。WeatherKit 条款要的 Apple Weather 署名不放（手机端不显示天气数据、且只走 TestFlight 不上架，寻 09-14 定）。
- **推送**：APNs（`PushRegistrar`），克的 knock、网关告警、晨间紫外线走它。
- **手表端** `Watch/`：腕上健康中继——表自己读健康库自己推（不等手机解锁），睡眠写库那刻补推；登录票由手机经 WatchConnectivity 传去，表上不登录。
- **形态**：iOS 16.4+、只做 iPhone、竖屏；watchOS 10+。寻的手机 iPhone 11 / iOS 27（打包机 Xcode 26.6 的模拟器只有 iOS 26 运行时），无灵动岛不做；验收以真机为准。设计/交互改动先出截图班给寻点头再出包，修 bug 直接出。
- **手表端已有**（09-15～09-21）：表上看对话、打字、长按说话（直连腾讯断了就 `transcribe=1` 交网关兜底转写）、表盘复杂功能（`Watch/Widget`，矢量画的克——表盘上位图一律灰饼，只能矢量）。
- **语音条（09-15 定稿 A 版）**：按住说话，腾讯 ASR 直连边说边出字、松手即发，左滑取消、右滑编辑；m4a 整段传 `/api/voice` 长期留在服务器。
- **相册抽屉（09-22）**：iOS 26 起系统 sheet 非满屏必浮起成卡片（两侧底部离屏边＋描边，无公开 API 关）——寻不要边框，半屏/四分之三抽屉一律不走 sheet，用 `overFullScreen` 自画贴边面板（`EmbeddedPickerVC` 是样板）；嵌入式 `PHPickerViewController` 顶上 16 灰内距关不掉，用同色盖条压；玻璃圆钮栏要 `bringSubviewToFront` 否则阴影被后加视图切平。
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
- Apple 每日 TestFlight 上传有上限：24 小时十几包够用（09-14 一天八包没被拒）；攒包是为了别一条一包，不是「最多两三包」。
- `-f inspect=true`＝只归档查包不上传；截图班跑完会拷模拟器崩溃报告与 `log show` 到产物 `crash/`。
- 同一分支上新班次会取消进行中的旧班次（`concurrency`）：推完立刻派 testflight 会把截图班掐掉，要截图就等它跑完再派。

## 签名与密钥（已办）

手动签名：用 App Store Connect API 申请的 Apple Distribution 证书＋App Store 描述文件（手机 `Keep AppStore`、手表各一份），到期 **2027-09-02**；原件在 `密钥与登录\ios-signing\`，仓库密钥见 `ios.yml` 里「落 App Store Connect 密钥」「装签名证书与描述文件」两步用到的名字。到期或换证书重跑申请脚本（CSR → `POST /v1/certificates` → `POST /v1/profiles`）。APNs 密钥在服务器 `.env`（`APNS_*`），仓里没有。Apple ID 密码不上任何服务器。

## 心愿单（寻提的，未排期）

- 地图栏去留；克发 HTML 的做法（正文 ```html 块 App 画成卡，还是新工具走班车）。

## 踩坑册

`https://github.com/Cheiineeey/ios-app-where-it-breaks`——签名、来电界面、推送、健康权限的真机踩坑记录。要点：报错文字常指错方向，查 `codesign -d --entitlements -` 与 `plutil -p Info.plist` 看包里实况；VoIP 推送与普通推送是两套令牌。
