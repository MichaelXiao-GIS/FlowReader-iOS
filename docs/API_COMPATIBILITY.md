# 账号接口兼容记录

核对日期：2026-10-31。此记录描述兼容实现的证据，不代表 SFACG 提供公开、稳定的开发者 API。

## 参考材料

- [SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject/tree/3fa06a01db2a98585fa3abb77c4be9af0bcb856e)：网页账号、书架、VIP 等级、已订阅章节与 App 请求协议。
- 用户提供的 Android 安装包：`com.sfacg`，版本 `5.2.84`，版本号 `5284`。SHA-256：`c2ed6f5df7fe9dc82c98ac59579b3e19bfd68e51c2570c14d13da65475efcb10`。
- APK 带有 Secneo 包装。静态分析确认了接口路径、部分字段及用户资料 expand 字符串；没有完整还原业务代码。因此，路径字符串本身不作为请求方法或响应格式已经确认的证据。
- APK、提取资源、反编译文件和真实账号响应均不进入仓库与发行包。客户端协议由本项目以 Swift 独立实现。

## 网页书架的 HTTP 500

参考实现 `src-tauri/src/adapters/sfacg/web/catalog.rs` 明确说明，网页端的有声、视频收藏分类可能返回 HTTP 500。参考实现跳过这些分类及失败的后续分页，保留其他分类的结果。

旧版 Swift 实现把任何一个分类失败视为整次同步失败，账号页随后又显示空书架。本版按分类隔离失败，返回可读取作品和部分同步提示。全部分类失败、目录请求失败、会话失效仍显示错误；取消请求不作为网络故障显示。没有真实请求记录时，不能仅凭截图确定具体哪一个分类返回了 500。

同一书架页面在携带账号 Cookie 时可能返回不含作者的精简卡片，而公开页面包含作者链接。遇到缺失作者的页面时，客户端以无 Cookie 请求读取同一公开页面，只按作品 ID 补全作者；保留账号请求得到的书籍、标题和分类。公开信息不可读时不会丢弃账号书架，也不会猜测作者。此方式按页补全，避免为每本书单独请求详情。

## VIP 资料与章节权限

网页 VIP 资料使用参考实现中的 `pages.sfacg.com/api/User?expand=newVip`，依据 `newVip.isNewVip` 选择新 VIP 等级或 `api/common/vipInfo` 的旧 VIP 等级。App 用户资料的 expand 列表包含 `vipInfo,newVip,member,dianyamember`，也见于所提供 APK。

VIP 等级、会员有效期和单章订阅权限是不同概念。只显示已经确认含义的服务器字段，未确认的会员状态不推断为已开通或未开通。已订阅文字章节仍由官方网页会话取得授权图片，再由本机 Apple Vision 识别。应用不自动购买章节。

目录权限通过同账号的认证 App 请求读取。明确的 `has=true` 显示“已购买”；当前账号 `needFireMoney` 为有效数值零，或同一会话已成功读取正文时显示“可阅读”。真实对照确认同一章节在认证请求中为零价、匿名请求中为正价。零价也可能来自赠阅或活动，不能据此捏造购买交易。“可阅读”与“已购买”因此分别显示，只有明确未购状态才画锁；缺失或异常字段显示普通 VIP 标记。权限只保留在当前会话内，旧目录缓存和账号余额不作为购买证明。

VIP 图片解析参考上游 `src-tauri/ocr-worker/ocr_worker.py` 的多帧、38 像素行高、顶部 5 像素留白及拼音层处理。原生实现逐帧、分块识别，去除拼音注释区域并保留深色正文。直接把整张图片交给文字识别会混入拼音和背景，并可能丢失后续帧。新的缓存格式版本为 2，旧 VIP 缓存下次读取时重新获取并识别；更新失败时保留原文件并提示重试，不把旧乱码重新展示为正文。

## 每日签到

提交行为来自参考项目 [client.ts](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/3fa06a01db2a98585fa3abb77c4be9af0bcb856e/src/client/Sfacg/api/client.ts) 的 `newSign()`：`PUT /user/newSignInfo`，JSON 正文包含 `signDate`。该路径也出现在 APK 的明文协议字符串中。成功奖励采用参考类型中的 `name`、`num` 字段；服务器明确提示当天已签到时，不重复宣称获得奖励。

日期格式为北京时间 `YYYY-MM-DD`，依据历史版本中的 [getNowFormatDate](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/b508d2dae5df877f4f919b213b1881216e9da47a/src/client/utils/tools.ts)。不能使用设备所在时区替代。

无会话只读探测发现 `GET /user/newSignInfo` 返回 404，因此没有把提交地址直接当作查询地址。APK 中另有 `/user/signInfo`；它与 `/user/member/status` 的无会话 GET 请求均返回 401 和需要登录的提示。真实已签到账号的 `/user/signInfo` 返回成功信封及空数组；这不是损坏数据，也不证明当天尚未签到。日历数组未提供可靠状态时保留未知，不显示为“未签到”。明确的签到回执优先于可选详情查询，连续天数读取失败不会再覆盖已确认结果。已确认状态按经过哈希的 App 账号标识和北京时间日期缓存，换号与跨日不复用。签到只由用户按钮触发。

网页和 App 登录各自保有独立会话。会员与签到页面展示实际使用的账号昵称；不会把网页 Cookie 转换为 App 会话。正式会员有效期字段尚未确认，当前只提供已确证的新旧 VIP 等级。

## 云端阅读位置

官方移动网页章节在打开后调用 `POST https://m.sfacg.com/API/Book.ashx?op=addviewrecord`，表单字段为 `bookid` 与 `articleid`。App 的 `GET /user/NovelViews` 返回 `accountId`、`novelId`、`chapterId`、`lastViewTime` 和 `unreadChapCount`。真实账号验证保持原章节 ID 不变提交后，App 记录的服务器更新时间推进，确认这两条路径使用同一阅读记录。

客户端在正文成功显示 3 秒、仍处于该章节且应用位于前台时提交章节；滚动、下载、导入与打开书库不提交旧进度。请求和结果校验会话代际，读取时还核对 Web/App 账号一致以及记录的账号 ID。云端同步精确到章节，段落位置保存在本机；不同章节由读者点击“从云端继续”选择，不自动覆盖本机位置。

真实 `lastViewTime` 为不带时区的 ISO 日期，客户端不擅自假定其时区，也不用它覆盖本机较新的进度。`m.sfacg.com/history/` 与 `getViewHistorys` 只包含书籍访问记录，不作为章节位置；`pages.sfacg.com/api/user/NovelViews` 实际返回用户资料，未使用。
