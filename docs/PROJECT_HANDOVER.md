# 菠萝阅 / Flow Reader：迁移复工记录

整理日期：2026-11-07。依据迁移目录中的源码、项目配置、历史验证记录、安装包，以及当天读取的 GitHub 分支、提交、Release 和公开问题列表。本文记录复工基线，不代表在新 Mac 上完成了构建、真实账号或真机验证。

**同日复工进展：** 后续已打开 Xcode 工程，确认许可与首次初始化检查通过，安装缺失的 Metal Toolchain 27B47，并以全新构建目录在两个独立 iOS 27.2 模拟器上分别完成 336 项单元测试，均零失败、零跳过。新环境验证明细见 [验证记录](VALIDATION.md)；下文“此次未运行”“尚未接受许可”等表述保留为初次迁移检查的历史状态。

**同日后续版本 1.7.1 / build 13：** 根据用户要求，日常登录统一为“登录菠萝包”；旧网页授权移至“我的 → 兼容设置”，账户余额区不再重复提供登录按钮。会员、书库及未登录 VIP 阅读统一引导主账号，会员页不再让旧网页身份读取干扰 App 账号。重新核对了 APK 的登录/正文接口与 `.SFCommunity` 同步 WebView 实现，证据和局限见 [账号接口兼容记录](API_COMPATIBILITY.md)。两机各 337 项单元测试及 8 项相关 UI 流程通过；已准备新版未签名真机包，发行下载见 [v1.7.1](https://github.com/MichaelXiao-GIS/FlowReader-iOS/releases/tag/v1.7.1)。真实账号由用户安装后验证；下文“源码未变”和 1.7.0 版本表描述的是最初迁移检查阶段。

## 1. 当前基线

| 项目 | 核对结果 |
| --- | --- |
| 仓库 | [MichaelXiao-GIS/FlowReader-iOS](https://github.com/MichaelXiao-GIS/FlowReader-iOS) |
| 本地分支 / 远端默认分支 | `main` / `main` |
| 本地 HEAD / 当天远端 main | 均为 `500a03a165a3831882b0bc07f108f2fd39a75089` |
| 最新发布 | [v1.7.0 · 原生作者主页](https://github.com/MichaelXiao-GIS/FlowReader-iOS/releases/tag/v1.7.0)，2026-11-01 18:37 UTC |
| 应用版本 / build | `1.7.0` / `12` |
| 最低系统 / 发行架构 | iOS `27.0` / `arm64` |
| 旧机器构建环境 | 文档记载 Xcode 27.1（27A9275），iOS 27.1 SDK |
| 新机器已安装环境 | 实查 Xcode 27.2（27B52），iPhoneOS / iPhoneSimulator 27.2 SDK |
| 项目语言设置 | `SWIFT_VERSION = 5.0`，这是 Swift 语言兼容模式，不是已安装编译器版本 |
| 依赖 | 无外部包管理依赖；使用 Apple 系统框架，Metal 构建需要对应 Toolchain |
| 工程 / scheme | `FlowReader.xcodeproj` / `FlowReader` |
| Bundle Identifier | `com.michaelxiao.flowreader`，工程未绑定个人 Team |
| GitHub 待办 | 当天未发现 open issue 或 open PR；当前仓库树没有 `.github/workflows` 文件 |

迁移后 158 个 Git 跟踪文件中，156 个普通文件被增加了可执行位。已先确认忽略文件模式后工作树内容与 HEAD 一致，再只移除这些文件的多余执行权限；两个原本可执行的脚本保留执行权限。恢复后工作树干净，随后新增本文。没有改动应用源码、版本、提交或远端仓库。

## 2. Purpose：我们在做什么

为个人阅读开发独立第三方菠萝包轻小说客户端，中文名称“菠萝阅”，英文名称 Flow Reader。以 SwiftUI 原生导航、系统 Liquid Glass、Apple Books 风格书架与阅读排版提供连贯的发现、阅读、下载和续读体验。无广告、无第三方分析 SDK；代码按 GPL-3.0 发布。

关键产品取舍：

- 保留原生标签栏、侧栏、导航、弹层和系统无障碍行为；通过可用空间、安全区域和局部遮挡适配 iPhone 18 Pro、iPhone Duo 内外屏与横竖屏。
- 阅读以正文为中心，工具默认隐藏；支持上下滚动、仿真翻页、可选横屏双页和细粒度阅读位置恢复。
- 使用读者已获授权的内容；单章订阅由用户明确确认，普通阅读和下载关闭自动订阅。
- 云端章节记录与本机段落位置各有职责，不同章节的云端续读由读者主动选择。
- 当前范围是小说阅读及相关账户功能；漫画阅读、EPUB 导入、作者关注/私信/动态均未纳入已交付功能。

## 3. Input：输入材料与依赖

| 输入 | 在开发中的用途 | 当前状态与注意点 |
| --- | --- | --- |
| 上游 [SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject/tree/3fa06a01db2a98585fa3abb77c4be9af0bcb856e) | 参考 App / Web 接口、签名、登录、书架、音频和正文处理行为 | Swift 原生重写；来源与 GPL 说明见 `NOTICE.md`，并非把上游跨平台应用直接包装成 iOS App |
| 用户提供的 `boluobao.apk` | 核对 Android 5.2.84 / build 5284 的协议及界面业务判断 | 本地仍有文件，未进入 Git；历史记录只恢复部分 DEX 结构和调用，不等于完整反编译 |
| SFACG 在线服务 | 搜索、书籍、目录、作者、账号、云书架、已授权正文、音频、福利等 | 服务端可能变化，历史成功不保证当前仍可用；此次未重新连接读者账号 |
| 正文字典 | 还原 App 接口的单字置换 | 3760 项映射，随应用资源分发；只用于已经授权的 App 正文 |
| 用户本地 TXT / GB18030 文本 | 本地书库导入 | 支持导入、阅读、进度与导出；EPUB 当前仅支持导出 |
| 原创样书与测试夹具 | UI、分页、下载、账号状态、购买与福利异常路径验证 | 《在风抵达之前》等样本；专用场景用 Debug 与双启动参数隔离 |
| Apple 原生技术与设计参考 | SwiftUI、UIKit、Core Text、Metal、Vision、AVFoundation、MediaPlayer、Security / Keychain、Icon Composer | 图标源文件、截图和历史设计依据均保留 |

项目目录迁移保留的是开发资料、源码和构建产物。不能据此认定旧模拟器中的个人书库、系统钥匙串、Apple 签名身份或旧机器的外部分析工具也已迁移。`SessionVault` 使用 `ThisDeviceOnly` 保护会话，新开发环境应按需重新登录，不从旧构建产物寻找登录材料。

## 4. Process：此前的实现与迭代

历史提交和 Release 显示，主要开发集中在 2026-10-31 至 2026-11-01。迭代方法是：对照上游和 APK 确认协议 → 原生 Swift 实现及状态隔离 → 离线解析/请求/异常测试 → 两种机型 UI 验证 → 有限真实服务核对 → 未签名真机打包及 Release。

| 版本 | 主要进展 |
| --- | --- |
| 1.0.0 | 原生应用骨架、发现和搜索、网页账号、本地阅读与下载、导入导出、朗读和音频、Liquid Glass 与 Duo 布局 |
| 1.0.1 | 一级云端/本机书库、分类失败保留部分结果、作者补全、云端章节续读、VIP 图片识别、签到确认和钥匙串修复 |
| 1.1.0 | 沉浸阅读、系统卷页、Core Text 分页、横屏双页、按文字位置恢复、紧凑遮挡避让、白底分层图标 |
| 1.2.0 | 统一 App 主账号、App 书架与授权正文接口、Books 式阅读工具、日常福利与会员礼包 |
| 1.3.0 | 自研 Metal 二维跟手纸张卷曲、三列书库、冷启动阅读恢复、进度小文件、封面降采样、本地生命周期诊断 |
| 1.4.0 | 修复 App 字符置换遗漏与旧缓存；显示火券/代券/金币；报价、确认与不确定结果保护的单章订阅 |
| 1.5.0 | 云书架按最近阅读排序、章节百分比、真实消费记录补齐已购标记、三列纵向推荐 |
| 1.5.1 | 长目录定位当前章、正倒序记忆、跨卷顺序保护、切章按钮命中区及冷启动目录权限修复 |
| 1.5.2 | 账号真实头像、失败占位和换号清理 |
| 1.5.3 | 会员礼包冷却负值兼容：身份及会员资格确认后，`residueDay <= 0` 可手动领取 |
| 1.6.0 | 实际前台小说阅读时长计量、北京时间跨日、空闲暂停和增量上报，福利进度以服务端回读为准 |
| 1.7.0 | 原生作者资料、头像/简介/粉丝数/全部公开小说、多层作品导航与原生返回 |

最新一次更新停在作者主页交付完成，没有从仓库中找到已确定的下一版本功能范围。下文的复工顺序是基于现状的建议，不是此前已经承诺的路线图。

## 5. 代码入口和职责

| 工作内容 | 主要入口 | 需要一起理解的部分 |
| --- | --- | --- |
| 启动、环境对象、页签、全屏阅读 | `FlowReader/FlowReaderApp.swift`、`UI/RootView.swift` | `UI/ReadingRoute.swift`、`Storage/AppLifecycleDiagnostics.swift` |
| 统一 API、登录和会话 | `Core/SFAPI.swift`、`Core/SessionVault.swift`、`Core/AccountConnections.swift` | `SFAPI` 为 actor；Web 与 App 独立保存，会话代次阻止旧响应污染新账号 |
| 书籍、章节和本地兼容模型 | `Core/Models.swift` | `authorID` 为可选；保存的目录不持久化当前会话权限 |
| 发现、书籍详情、作者页面 | `UI/DiscoverView.swift`、`UI/BookDetailView.swift`、`UI/AuthorProfileView.swift` | `Core/Authors.swift`、`UI/AuthorProfileState.swift` |
| 云书架及章节进度 | `UI/CloudLibraryStore.swift`、`Core/AppBookshelf.swift`、`Core/CloudProgress.swift` | `Core/CloudReadingCatalog.swift`、`Core/WebBookshelfLoader.swift` |
| 章节正文及缓存修复 | `Core/AppChapterContent.swift`、`Core/AppContentDecoder.swift`、`Storage/LibraryStore.swift` | `Core/SFVIPContent.swift` 为网页授权图片/Vision 兼容路径 |
| 权限、余额和单章订阅 | `Core/ChapterSubscriptionRecords.swift`、`Core/ChapterOrdering.swift`、`Core/SFChapterPurchases.swift` | `Core/AccountWallet.swift`、`UI/ChapterPurchaseViewState.swift`、`UI/ChapterPurchaseSheet.swift` |
| 阅读页面与目录 | `UI/ReaderView.swift`、`UI/ReaderChrome.swift`、`UI/ReaderContentsSheet.swift` | `UI/ReaderContentsPermissions.swift`、书签及章节导航 |
| 排版、遮挡、翻页 | `Reading/ReaderPagination.swift`、`Reading/ReaderViewportLayout.swift`、`Reading/CurlPageLayout.swift` | `CurlPageReader.swift` → `FlexiblePageController.swift` → `ReaderCurlMetalRenderer.swift` / `ReaderCurl.metal` |
| 真实阅读时长 | `Reading/ReadingTimeLedger.swift`、`Reading/ReadingTimeReporter.swift` | `Core/ReadingTimeReporting.swift`、`UI/DailyWelfareView.swift` |
| 签到与礼包 | `Core/SignIn.swift`、`Core/DailyWelfare.swift`、`Core/MemberGifts.swift`、`Core/SFMembership.swift` | 对应 UI 状态、回执确认及账号隔离 |
| 本地书库、下载、导入与导出 | `Storage/LibraryStore.swift`、`Storage/BookExporter.swift` | `Storage/ReaderBookmarkStore.swift`、`UI/LocalLibraryView.swift`、`UI/DownloadsView.swift` |
| 朗读和有声 | `Reading/AudioController.swift`、`Storage/AudioLibrary.swift` | `UI/AudioPlayerView.swift`，系统媒体及锁屏控制 |
| 工程与发布 | `FlowReader.xcodeproj`、`scripts/generate-project.py`、`scripts/package-unsigned.sh` | 版本和 build 同时存在于生成脚本及工程配置，更新时保持一致 |

运行路径：发现/书库选书 → 作品详情及目录 → `ReadingSession` 打开独立全屏阅读器 → `LibraryStore` 先读可用缓存，再按会话取得授权正文 → 字符还原或网页 OCR → 滚动/分页显示 → 本机文字位置保存、符合条件的章节云同步和独立阅读计时。

本地数据采用 JSON 文件与 UserDefaults，而非 Core Data / SwiftData。书库根目录位于应用的 Application Support / `FlowLibrary`，包含 `library.json`、`downloads.json`、按作品保存的章节正文和 `reading-progress.json`；音频在 `FlowAudio`。项目目录不是这些运行时用户数据的备份。

## 6. 下次修改必须保留的行为

1. **身份与权限隔离。** App 主账号优先；可选网页会话失效不阻断 App 书架，也不能静默切换到另一个网页账号取得正文。缓存、晚到响应和提交均检查账号/会话代次。
2. **正文只还原一次。** `isContentEncrypted=false` 不代表可直接显示。新 App 正文和明确标记为 v3 的旧 App 缓存执行单次映射，原子保存为 v4；网页 OCR v2、本地导入和 v4 不再次转换。该映射不是幂等操作。
3. **区分可读与付费事实。** 零价或成功读到正文可确认“可阅读”；已购买依赖明确字段或对应消费记录。缺字段、分页失败、未知余额不当作“未购买”或零。
4. **购买明确确认。** 阅读/下载关闭 `autoOrder`；单章购买绑定账号、作品、章节、报价与有效期，提交前重新核验。价格变化需重新确认；含糊回执持久保存待确认状态，只读查证，不自动重复扣款请求。
5. **本机进度保持文字锚点。** 保存章节、段落和段内 UTF-16 偏移；分页随字号/窗口变化，页码不能作为永久位置。目录倒序仅改变展示，不改变上下章顺序。
6. **云进度和时长分开。** 章节正文显示约 3 秒且仍处于前台才同步章节；时长采用实际经过时间，按小说/章节及北京时间日期切分，后台、弹层、加载、自动朗读和两分钟无操作时暂停。未确认增量不重放，不跨进程补算，也不以本地秒数伪造福利完成。
7. **失败保留已确认结果。** 书架部分分类失败、订阅分页失败、作者资料/作品刷新失败时保留已获取内容；取消请求不当作服务故障。成功签到/领奖回执不能被不可靠的后续查询覆盖。
8. **布局依赖空间。** Duo 不靠设备名或固定方向推测；遵守安全区域和局部遮挡。横屏双页要求每栏正文至少 `max(240 pt, 当前字号 × 8)`、正文高度至少 240 pt。
9. **保持数据兼容。** 作者 ID 为可选，旧本地书籍能解码；未完成下载在重启后暂停；退出阅读与被系统终止后恢复是不同状态。

`docs/DESIGN.md` 中写有 1.1.0 的系统 `pageCurl` 历史方案。当前 1.7.0 代码优先使用自研 Metal 卷曲；Metal 不可用时有系统回退，减少动态效果采用系统分页滑动。不能把早期设计段落当作当前唯一实现。同样，1.2.0–1.3.0 的正文历史验证曾不充分，正文正确性的后续修正见 1.4.0 记录。

## 7. Output：已经交付了什么

- 158 个原有跟踪文件，包括原生 Swift 源码、Xcode 工程、资源、GPL 许可、45 个单元测试文件、UI 测试、设计和接口记录。
- 本地 `dist/` 保留 1.0.0–1.7.0 共 12 个未签名 IPA，以及发布截图、最新校验文件和部分发行审计；GitHub 也有对应 12 个 Release。
- `docs/screenshots/` 保留版本化模拟器截图；这些是历史成果及原创离线验收画面，不是此次在新 Mac 上运行的截图。
- `build/` 保留旧机器的 device / simulator / signed-simulator 构建目录；复工应另用新的 DerivedData 路径，不将旧缓存视为新环境验证。
- 图标源文件为 `Resources/FlowIcon.icon`，配有预览；应用资源包含 Metal 着色器与正文字典。

本次重新核对的最新 IPA：

```text
文件：dist/FlowReader-1.7.0-unsigned.ipa
大小：8,491,106 bytes
SHA-256：c0d1d947f229ad3ae84dd08e08dca56a8e9b92e13b371b09b1f5757bc8ce2237
```

本地计算值与 GitHub Release asset 的 digest、历史审计一致；`unzip -t` 通过。正文字典重新计算的 SHA-256 为 `af5863d70776d9f14a236ee2229eecfb2fccdcb00f095404e412e5f3d7bd6831`，与来源记录一致。

## 8. 验证证据与未完成事项

| 项目 | 已有证据 | 当前仍不能声称的结果 |
| --- | --- | --- |
| 1.7.0 单元测试 | 旧记录：18 Pro / iOS 27.0 全量 336 项通过；Duo / iOS 27.1 新增相关 16 项通过。源码静态计数也为 336 个测试方法 | 本次没有运行这 336 项；Duo 的 16 项不是全量 336 项 |
| UI 测试 | 当前源码有 14 个 UI 测试方法；各版本分批记录两机验证。1.7.0 验证作者多层导航、旋转和既有推荐网格 | 不能据此声称 1.7.0 两机完整 14 项一次性全部重跑 |
| 真实服务 | 历史核对搜索/目录/授权正文/余额/书架/云记录/消费记录/会员状态，以及三位作者、15 本公开作品 | 此次未重新测试当前 SFACG 服务 |
| 单章购买、签到和领奖 | 协议、确认、并发和不确定结果有离线覆盖；部分状态真实读取过 | 真实扣款、新签到奖励、日常奖励和会员礼包领取并未完成端到端实测 |
| 时长与 App 云进度写回 | 1.6.0 计时和回执离线测试；App 云进度请求构造验证；更早网页写回有历史真实证据 | 不等同于当前 App `PUT` 云进度和阅读时长已在真实账号成功入账 |
| 翻页和恢复 | 模拟器、离屏 GPU 与重启恢复验证；有本地运行诊断 | 不等同于真机帧率、能耗或用户此前重载原因已确认 |
| 有声与签名 | 播放/缓存/锁屏功能代码、未签名 arm64 IPA | 授权音频、蓝牙/中断/后台连续播放、重新签名和真机侧载仍需完整验证 |

Duo 外屏原生侧栏靠近右下相机的视觉间距，是旧记录中的已知系统布局限制；之前对安全区域做的两个尝试未生效，已移除。后续若处理，应重新检查实际系统行为，不恢复无效补丁。

## 9. 新 Mac 复工步骤

### 9.1 先完成 Xcode 初始化

此次 `/usr/bin/git` 与 `xcrun simctl list devices available` 明确返回尚未同意 Xcode 许可，退出码 69；`xcodebuild -checkFirstLaunchStatus` 也返回 69。`xcodebuild -version` 可以读取版本，但不表示开发环境已就绪。本次只使用已安装 Xcode 内的 Git 可执行文件完成只读版本核查，没有接受许可或执行系统初始化。

由用户打开 Xcode，阅读并接受许可、完成首次组件安装。之后检查：

```sh
xcodebuild -checkFirstLaunchStatus
xcodebuild -version
xcrun simctl list devices available
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader -showdestinations
git status --short --branch
```

根据可用设备建立测试环境。旧记录是 iOS 27.0 / 27.1，新机已安装 SDK 为 27.2；SDK 存在不证明对应模拟器 runtime 或设备已经安装。需要在 Xcode Components 中确认模拟器与 Apple Metal Toolchain；缺失时再安装，避免直接沿用旧机器设备 ID。

### 9.2 建立新环境基线

打开现有 `FlowReader.xcodeproj`，无需重新生成工程或引入依赖管理工具。工程使用文件系统同步目录，会自动收录对应源目录的新文件。

用新 DerivedData 目录和实际模拟器 UDID 运行全量单元测试：

```sh
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader \
  -destination 'platform=iOS Simulator,id=<实际模拟器UDID>' \
  -derivedDataPath build/resume-27.2 \
  -only-testing:FlowReaderTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

保留临时模拟器签名，才能正确测试系统钥匙串；不要把真机未签名打包参数照搬到测试命令。随后按改动范围运行 UI 测试，至少包含发现→详情→作者→作品返回、下载→阅读→切章→续读、目录定位/倒序、排版重排、卷页/双页、冷启动恢复；账户相关修改再加入对应离线夹具流程。

Duo 的姿态曾不能仅由 `XCUIDevice.orientation` 切换，须核对实际活动屏幕及窗口尺寸。因姿态不满足而跳过的用例不能记作通过。尽量用独立测试模拟器，保留个人设备的书库和会话。

### 9.3 下一次更新的建议顺序

1. **恢复可构建基线。** 完成许可/组件、新环境单元与核心 UI 验证；若 27.2 引入编译或布局变化，先修复并记录。
2. **确定单一更新目标。** 目前没有未合并工作或明确下一版需求；从用户的实际问题或新功能出发，在上表定位对应模块，不预先指定 1.8.0 内容。
3. **优先补齐与该目标相关的证据。** 真机重载/恢复和卷页、授权音频，以及真实时长/云写回是现有主要验证缺口；购买/领奖等真实账号动作须单独明确需要验证什么。
4. **实施与回归。** 接口改动同时更新 `API_COMPATIBILITY.md`；布局改动检查普通手机、Duo、旋转、大字号与减少动态效果；存储变更验证旧索引和 v2/v3/v4 正文。
5. **打包前更新工程与生成脚本的版本/build。** 执行 `./scripts/package-unsigned.sh`，核对 ZIP、架构、版本、Metal 库、字典、未签名状态与包内资源，生成 SHA-256。发布说明明确区分本次模拟测试、真实服务测试和未验证范围。

`scripts/package-unsigned.sh` 会按项目版本写入 `dist/FlowReader-<version>-unsigned.ipa`；下一版应先更新版本，以免覆盖此次已核对的 1.7.0 安装包。当前没有仓库内 GitHub Actions 配置可替代本地 Xcode 验证。

## 10. 以后恢复上下文时先读

1. 本文：当前基线、模块入口、迁移条件和验证缺口。
2. [README](../README.md)：已交付功能与用户使用边界。
3. [接口兼容记录](API_COMPATIBILITY.md)：协议证据、参数和业务语义。
4. [验证记录](VALIDATION.md)：各版本已测范围及局限，按版本辨读历史信息。
5. [设计说明](DESIGN.md) 与实际阅读器源码：历史设计选择和当前实现。
6. [来源说明](../NOTICE.md)：上游、字典、APK、图标与许可来源。

复工起点：以 `500a03a` / v1.7.0 为已发布基线，在 Xcode 27.2 新环境完成初始化及基线验证，再根据下一次明确需求进行增量修改。
