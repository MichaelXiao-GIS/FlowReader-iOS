# 菠萝阅 | Flow Reader

<img src="Design/FlowIcon-preview.png" width="96" alt="菠萝阅分层图标">

面向个人阅读的原生 iOS 菠萝包轻小说第三方客户端。SwiftUI、系统 Liquid Glass 导航、Books 风格书架与阅读排版，无广告、无第三方分析 SDK。

**要求：iOS 27.0 或更新版本。** 使用 Xcode 27.1 / iOS 27.1 SDK 构建，支持 iPhone 18 Pro 与 iPhone Duo。Duo 使用原生侧边标签栏，阅读目录采用系统自适应弹层；内外屏及折叠姿态交给系统导航和安全区域适配。

## 安装

从 [Releases](https://github.com/MichaelXiao-GIS/FlowReader-iOS/releases) 下载 `FlowReader-1.0.0-unsigned.ipa`。这是 **arm64 真机未签名 IPA**，需自行用个人 Apple 开发签名或现有侧载工具重新签名安装；它不含开发者证书、描述文件或 Apple 账号。

## 功能

- 在线搜索、推荐、书籍详情、分卷目录和免费章节阅读。
- 官方网页登录、账号书架；可选独立 App 会话连接有声服务。密码只用于当次登录，不持久化；会话隔离保存在系统钥匙串。
- 章节选择下载，暂停、恢复、取消；重启后未完成任务暂停，避免自动继续请求。
- 本地书库、TXT / GB18030 导入、阅读进度恢复、字号、行距、字体与主题设置。
- 系统语音朗读、连续章节、有声音轨播放、睡眠定时、锁屏控制、单集离线下载和音频分享。
- 导出已下载正文为 TXT、Markdown 或 EPUB。
- 原生 Icon Composer 分层图标：奶油白背景、蓝色书页与菠萝叶，系统渲染 Liquid Glass 材质及外观变体。

## 构建

无需第三方依赖或项目生成工具。直接打开 `FlowReader.xcodeproj`，选择 `FlowReader` scheme。个人签名时在 Signing & Capabilities 中选择自己的 Team，并按需修改 Bundle Identifier。

```sh
# 创建可重新签名的真机 IPA
./scripts/package-unsigned.sh

# 运行测试；替换为自己的模拟器名称
xcodebuild -project FlowReader.xcodeproj -scheme FlowReader \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

`scripts/generate-project.py` 可重建 Xcode 工程。工程使用文件系统同步目录，新增 Swift 文件会自动收录。`--demo` / `--uitesting` 启动参数使用明确标注的原创样书，正常启动请求真实服务。

## 使用边界

本项目独立于 SFACG 官方，接口可能随服务端调整。已购 VIP 文字依赖官方网页会话，图片正文使用本机 Apple Vision 识别；未订阅章节提示前往官方订阅，不自动购买。有声音轨依赖 App 会话和账号权限。

账号登录、已购 VIP 识别、真实授权音频及真机重新签名安装未使用个人账号完成端到端验证。漫画、EPUB 导入、翻页卷曲效果不包含在本版本；正文采用连续滚动阅读。下载应保持应用在前台，iOS 可能挂起后台网络任务。

验证结果与机型截图见 [验证说明](docs/VALIDATION.md)。

## 来源与许可

接口和功能参考 [Mios-dream/SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject)，原项目 README 声明 GPLv3。本项目原生 Swift 重写并以 GPL-3.0 发布，完整源码随仓库提供。具体来源及图标说明见 [NOTICE](NOTICE.md)。书籍内容、书封与平台商标仍属于各自权利人。
