# 原生设计实现

布局以 Apple Books 的内容优先、书封比例和阅读留白为参考。书架采用原生大标题、搜索与封面缩放转场；开启“减少动态效果”时不执行缩放。阅读器保持合适行长，支持动态字体、VoiceOver、深色与暖纸主题。衬线模式优先使用系统中可用的中文宋体字体，不可用时回退到系统衬线设计，实际字形随系统字体资源而定。

主导航的 TabView 使用 `.sidebarAdaptable`，iOS 27.1 使用 `.defaultTabBarPlacement(.sidebar)`。书架、发现与账号页保留系统导航；阅读器由根视图的 [`fullScreenCover(item:onDismiss:content:)`](https://developer.apple.com/documentation/swiftui/view/fullscreencover%28item%3Aondismiss%3Acontent%3A%29) 独立全屏呈现，主导航的标签栏与 Duo 侧栏不进入阅读画布。关闭阅读器后返回原先页面，不锁定设备方向。

阅读会话保留独立的作品、章节和目录快照，进度更新不会改变当前选择。阅读工具默认隐藏，状态栏隐藏，并向系统请求隐藏持续显示的系统叠层；滚动阅读轻点正文、仿真翻页轻点页面中央，呼出玻璃材质的顶部工具和底部章节控制。加载或错误状态保留关闭入口，VoiceOver 提供显示工具与退出操作。工具与正文遵守安全区域，不使用设备名或 `UIScreen.main` 推断布局。

仿真翻页的纸张画布延伸到屏幕边缘，顶部与底部留白也属于正在翻动的整张纸。外层容器读取当前安全区域，内层卷页视口铺满可用屏幕；`CurlPageLayout` 统一提供分页与绘制几何，正文默认左右各留 20 pt。iOS 27.1 使用系统提供的有效遮挡区域及其边距定位相机：角落遮挡主要保留顶部或底部空间，避免把粗粒度的左右安全区域扩展为整页高的空白边栏；页眉与页码另选不与遮挡相交的位置。缺少局部遮挡信息时按安全区域避让。纸张边缘不因内容避让而缩短。

目录与阅读设置使用原生自适应 sheet，支持中等与完整高度，由各自的 NavigationStack 提供标题和完成按钮。目录继续使用 sheet，不在阅读页附着 inspector。封面缩放转场与主导航标签栏保持原生实现。

1.1.0 提供上下滚动与仿真翻页两种阅读方式，默认上下滚动。仿真翻页由 [`UIPageViewController.TransitionStyle.pageCurl`](https://developer.apple.com/documentation/uikit/uipageviewcontroller/transitionstyle-swift.enum/pagecurl) 提供系统卷曲动画和随手势变化的过渡；轻扫或轻点页边切换页面。开启“减少动态效果”时，改用系统分页滑动过渡，避免卷曲动画。

横屏双栏是仿真翻页的可选设置。仅在阅读区域宽大于高、每栏正文宽度至少为 `max(240 pt, 动态字号缩放后的字号 × 8)`、正文高度至少 240 pt 时启用双页，空间不足时回到单页。条件使用扣除页内留白与遮挡后的正文尺寸，不设固定的整屏宽度门槛；同一机型的内外屏、旋转、字号及可用窗口变化都走同一条布局规则。

分页通过 Core Text 按当前页面尺寸、字体和行距测量正文，利用 [`CTFrameGetVisibleStringRange`](https://developer.apple.com/documentation/coretext/ctframegetvisiblestringrange%28_%3A%29) 得到每页实际容纳的文字范围，再继续排下一页。阅读位置保存为段落编号与可选的段内 UTF-16 偏移，重新分页时映射到包含该文字位置的页面，不把随字号和屏幕变化的页码作为永久进度。旧存档缺少段内偏移时从该段起始处恢复。云端仍同步到章节，本机保存更细的文字位置。

Duo 外屏纵向标签栏的位置与相机间距由系统管理。在 Xcode 27.1 的公开 SDK 中，没有找到只调整原生标签栏纵向偏移的接口；`toolbarVerticalEdge` 与 `ReservedRegion` 提供的是读取布局信息的接口。2026-10-31 在外屏相机位于右下方的模拟器姿态中，分别对 TabView 根视图增加 24 pt 的 `safeAreaInset` 和 `safeAreaPadding`，标签栏的截图纵向范围均保持 515–1152 像素，没有上移。两个实验均已移除。发布版保留原生位置，该方向相机与标签栏较近的视觉间距仍然存在。Apple 对原生控件的自动避让与垂直布局说明见 [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) 和 [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)。

依据：

- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Apple Books，iOS 27](https://support.apple.com/en-euro/guide/iphone/iphc1af7c57/27/ios/27)
- [Icon Composer](https://developer.apple.com/icon-composer/)

图标源文件为 `FlowReader/Resources/FlowIcon.icon`，由 Apple Icon Composer 建立。1.1.0 将浅色外观的奶油白渐变背景改为纯白填充，保留蓝色书页、菠萝叶与珊瑚书签前景，以及原有 Liquid Glass 材质；深色、单色与着色外观保持不变。前景由内置 image_gen 工具生成；前景设计提示词：

> 抽象的原生 iOS 阅读图标，两片蓝色书页组成紧凑的菠萝包轮廓，上方两片叶子，一处珊瑚色书签。4–5 个简洁形状，无人物、面孔、头发、文字或黑色描边，透明背景。高光、透光和阴影由 Icon Composer 的系统材质呈现。
