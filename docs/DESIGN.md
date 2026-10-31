# 原生设计实现

布局以 Apple Books 的内容优先、书封比例和阅读留白为参考。书架采用原生大标题、搜索与封面缩放转场；开启“减少动态效果”时不执行缩放。阅读器保持合适行长，支持动态字体、VoiceOver、深色与暖纸主题。

TabView 使用 `.sidebarAdaptable`，iOS 27.1 使用 `.defaultTabBarPlacement(.sidebar)`；目录使用原生自适应 sheet，支持中等与完整高度。系统工具栏负责纵向/横向控件布局，前景不越过安全区域，不使用设备名或 UIScreen.main 推断布局。没有强制全屏或方向锁定。

阅读路径使用独立值路由，阅读进度更新不会改变已选中的章节和目录快照。在目标 SDK 的回归测试中，将 inspector 附着在推进导航栈的阅读页会导致阅读页加载后立即消失；将目录呈现改为原生 sheet 后，下载、阅读、字号调整、切章、返回和续读闭环通过。封面缩放转场与系统标签栏保持原生实现。

Duo 外屏纵向标签栏的位置与相机间距由系统管理。在 Xcode 27.1 的公开 SDK 中，没有找到只调整原生标签栏纵向偏移的接口；`toolbarVerticalEdge` 与 `ReservedRegion` 提供的是读取布局信息的接口。2026-10-31 在外屏相机位于右下方的模拟器姿态中，分别对 TabView 根视图增加 24 pt 的 `safeAreaInset` 和 `safeAreaPadding`，标签栏的截图纵向范围均保持 515–1152 像素，没有上移。两个实验均已移除。发布版保留原生位置，该方向相机与标签栏较近的视觉间距仍然存在。Apple 对原生控件的自动避让与垂直布局说明见 [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) 和 [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)。

依据：

- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple Books，iOS 27](https://support.apple.com/en-euro/guide/iphone/iphc1af7c57/27/ios/27)
- [Icon Composer](https://developer.apple.com/icon-composer/)

图标源文件为 `FlowReader/Resources/FlowIcon.icon`，由 Apple Icon Composer 建立。奶油白渐变背景与独立前景接受系统 Liquid Glass 材质。前景由内置 image_gen 工具生成；最终设计提示词：

> 抽象的原生 iOS 阅读图标，两片蓝色书页组成紧凑的菠萝包轮廓，上方两片叶子，一处珊瑚色书签。4–5 个简洁形状，无人物、面孔、头发、文字或黑色描边，透明背景。高光、透光和阴影由 Icon Composer 的系统材质呈现。
