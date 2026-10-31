# 来源说明

接口及功能行为参考：Mios-dream / SFNovel-ReaderProject，版本 `3fa06a01db2a98585fa3abb77c4be9af0bcb856e`，https://github.com/Mios-dream/SFNovel-ReaderProject 。原项目 README 声明 GPL3.0；本项目依据该声明以 GPL-3.0 提供对应源码，未打包上游的小说封面、字体、OCR 模型或书籍正文。

协议参考路径：

- `src-tauri/src/adapters/sfacg/app/` 中的 `constants.rs`、`signing.rs`、`client.rs`、`catalog.rs`、`auth.rs`、`audio.rs` 与相关解析文件。
- `src-tauri/src/adapters/sfacg/web/` 中的 `client.rs`、`auth.rs`、`catalog.rs`、`content.rs`、`placeholder.rs`。
- `src-tauri/src/adapters/sfacg/device.rs`。
- `src-tauri/ocr-worker/ocr_worker.py` 中的多帧图片、固定行高和拼音层预处理方式；本项目以 Swift 与本机 Apple Vision 实现，不分发其 OCR 模型。

上游致谢 LanBaiCode/auto-novel 与 Oevani/Sfacg_Downloader 的接口及签名方案。

视觉参考 Apple Books 及 Apple 原生设计规范；不包含 Apple 专有界面素材。图标最初参考菠萝包官方 App Store 图标的配色，经图像生成工具重新设计为抽象书页、菠萝叶与书签；没有使用官方角色、名称字样或标识。最终图标为独立第三方设计，不表示官方合作或背书。

原创演示书《在风抵达之前》仅用于离线演示与测试。用户获取的小说文字、音频和书封不受本项目代码许可证重新许可。

用户提供的菠萝包 Android 5.2.84 安装包用于本地协议兼容核对，相关来源与边界记录在 `docs/API_COMPATIBILITY.md`。仓库和安装包不包含该 APK、反编译源码或提取的官方素材。
