# 菠萝阅 | Flow Reader

<img src="Design/FlowIcon-preview.png" width="96" alt="菠萝阅分层图标">

面向个人阅读的原生 iOS 菠萝包轻小说第三方客户端。SwiftUI、系统 Liquid Glass 导航、Books 风格书架与阅读排版，无广告、无第三方分析 SDK。

**要求：iOS 27.0 或更新版本。** 使用 Xcode 27.1 / iOS 27.1 SDK 构建，支持 iPhone 18 Pro 与 iPhone Duo。Duo 使用原生侧边标签栏，阅读目录采用系统自适应弹层；内外屏及折叠姿态交给系统导航和安全区域适配。

## 安装

从 [Releases](https://github.com/MichaelXiao-GIS/FlowReader-iOS/releases) 下载 `FlowReader-1.1.0-unsigned.ipa`。这是 **arm64 真机未签名 IPA**，需自行用个人 Apple 开发签名或现有侧载工具重新签名安装；它不含开发者证书、描述文件或 Apple 账号。

## 功能

- 在线搜索、推荐、书籍详情、分卷目录和免费章节阅读。
- 一级“书库”整合云端书架与本机书籍，支持搜索、分类筛选与继续阅读；单个收藏分类失败时保留已读取作品，并提示未完成的同步。
- 云端章节进度读取与同步；不同的云端位置可主动选择继续阅读，同一章保留本机段落位置。
- 新旧 VIP 等级查询；已订阅 VIP 章节通过官方网页授权读取。可选独立账号服务支持手动每日签到与有声播放，明确展示实际连接账号。
- 密码只用于当次登录，不持久化；网页与 App 会话隔离保存在系统钥匙串。
- 章节选择下载，暂停、恢复、取消；重启后未完成任务暂停，避免自动继续请求。
- 本地书库、TXT / GB18030 导入、阅读进度恢复、字号、行距、字体与主题设置。
- 沉浸式全屏阅读，默认隐藏阅读工具；滚动阅读轻点正文、仿真翻页轻点页面中央，即可呼出关闭、目录与设置。
- 默认上下滚动，可在阅读设置切换原生仿真翻页；左右轻扫或轻点页边翻页。开启“减少动态效果”时，使用原生分页滑动替代卷曲动画。
- 仿真翻页支持可选横屏双栏：阅读区域横向、每栏正文宽度至少 240 pt 且可容纳约 8 个当前字号的字、正文高度至少 240 pt 时显示双页。Core Text 按页排版，以段落和段内 UTF-16 位置保存阅读锚点，支持尺寸与字号变化后重新定位。
- 系统语音朗读、连续章节、有声音轨播放、睡眠定时、锁屏控制、单集离线下载和音频分享。
- 导出已下载正文为 TXT、Markdown 或 EPUB。
- 原生 Icon Composer 分层图标：浅色纯白背景、蓝色书页与菠萝叶，系统渲染 Liquid Glass 材质及外观变体。

## 构建

无需第三方依赖或项目生成工具。直接打开 `FlowReader.xcodeproj`，选择 `FlowReader` scheme。个人签名时在 Signing & Capabilities 中选择自己的 Team，并按需修改 Bundle Identifier。

```sh
# 创建可重新签名的真机 IPA
./scripts/package-unsigned.sh

# 运行测试；替换为自己的模拟器名称
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

模拟器测试需要本地临时签名，才能使用系统钥匙串；上面的 `CODE_SIGN_IDENTITY=-` 不需要开发者证书。发行脚本仅对待自行签名的真机 IPA 关闭签名。

`scripts/generate-project.py` 可重建 Xcode 工程。工程使用文件系统同步目录，新增 Swift 文件会自动收录。`--demo` / `--uitesting` 启动参数使用明确标注的原创样书，正常启动请求真实服务。

## 使用边界

本项目独立于 SFACG 官方，接口可能随服务端调整。已购 VIP 文字依赖官方网页会话，图片正文使用本机 Apple Vision 识别；未订阅章节提示前往官方订阅，不自动购买。有声音轨依赖 App 会话和账号权限。

图片文字识别仍可能存在个别错字。真实授权音频、App 账号签到和真机重新签名安装仍需验证。漫画与 EPUB 导入不包含在本版本。下载应保持应用在前台，iOS 可能挂起后台网络任务。

验证结果与机型截图见 [验证说明](docs/VALIDATION.md)。APK 核对证据、接口来源与未确认的部分见 [接口兼容记录](docs/API_COMPATIBILITY.md)。

## 来源与许可

接口和功能参考 [Mios-dream/SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject)，原项目 README 声明 GPLv3。本项目原生 Swift 重写并以 GPL-3.0 发布，完整源码随仓库提供。具体来源及图标说明见 [NOTICE](NOTICE.md)。书籍内容、书封与平台商标仍属于各自权利人。
