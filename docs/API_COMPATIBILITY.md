# 账号接口兼容记录

核对日期：2026-10-31。此记录描述兼容实现的证据，不代表 SFACG 提供公开、稳定的开发者 API。

## 参考材料

- [SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject/tree/3fa06a01db2a98585fa3abb77c4be9af0bcb856e)：网页账号、书架、VIP 等级、已订阅章节与 App 请求协议。
- 用户提供的 Android 安装包：`com.sfacg`，版本 `5.2.84`，版本号 `5284`。SHA-256：`c2ed6f5df7fe9dc82c98ac59579b3e19bfd68e51c2570c14d13da65475efcb10`。
- APK 带有 Secneo 包装。本轮从保留的数据中恢复了部分 DEX 字符串表、类型表、方法表及 Retrofit 方法/参数注解，并在附加代码区确认了部分原始调用的参数构造。业务代码没有完整还原；以下分别注明注解、实际调用、官方网页和只读响应提供的证据，路径字符串本身不作为请求方法已经确认的证据。
- APK、提取资源、反编译文件和真实账号响应均不进入仓库与发行包。客户端协议由本项目以 Swift 独立实现。

## 主要账号与 App 书架

已连接 App 账号服务时，书架、云端续读、正文和福利使用该 App 账号。网页会话是独立的可选兼容入口；过期网页会话不会阻断有效 App 账号，也不会以另一个网页账号替代 App 书架。保存有 Cookie 只代表存在会话材料，只有当前身份查询成功才显示连接已确认。会话切换会清除旧账号的云端缓存和内存权限；暂时查询失败后仍保留上一次已验证身份用于后续比较，防止不同账号的部分书架合并。

APK `PocketApi` 的方法注解和 `ShelfViewModel` 调用确认 `GET /user/Pockets?expand=novels,comics,albums,latestchapter`，该方法没有分页参数。`Pocket.build` 的类别映射为漫画 1、文字小说 2、有声 3、对话小说 4。本项目读取文字小说分类的 `expand.novels`，保留分类名，按作品编号去重，并从 `authorName` 等字段读取作者和作品资料。当前认证只读验证已确认完整分类、作者和小说集合可用；每个分类的 `accountId` 必须匹配本次 App 身份。异常分类保留部分同步提示，全部异常不会显示为已确认空书架。

## 网页兼容书架的 HTTP 500

参考实现 `src-tauri/src/adapters/sfacg/web/catalog.rs` 明确说明，网页端的有声、视频收藏分类可能返回 HTTP 500。参考实现跳过这些分类及失败的后续分页，保留其他分类的结果。

旧版 Swift 实现把任何一个分类失败视为整次同步失败，账号页随后又显示空书架。本版按分类隔离失败，返回可读取作品和部分同步提示。全部分类失败、目录请求失败、会话失效仍显示错误；取消请求不作为网络故障显示。没有真实请求记录时，不能仅凭截图确定具体哪一个分类返回了 500。

同一书架页面在携带账号 Cookie 时可能返回不含作者的精简卡片，而公开页面包含作者链接。遇到缺失作者的页面时，客户端以无 Cookie 请求读取同一公开页面，只按作品 ID 补全作者；保留账号请求得到的书籍、标题和分类。公开信息不可读时不会丢弃账号书架，也不会猜测作者。此方式按页补全，避免为每本书单独请求详情。

## VIP 资料与章节权限

网页 VIP 资料使用参考实现中的 `pages.sfacg.com/api/User?expand=newVip`，依据 `newVip.isNewVip` 选择新 VIP 等级或 `api/common/vipInfo` 的旧 VIP 等级。App 用户资料的 expand 列表包含 `vipInfo,newVip,member,dianyamember`，也见于所提供 APK。

VIP 等级、付费会员资格和单章订阅权限是不同概念。只显示已经确认含义的服务器字段，缺失状态不推断为已开通或未开通。已连接 App 账号时，正文使用 `GET /Chaps/{chapterID}?expand=content&autoOrder=false`。接口注解与参考项目证明读取路径，认证只读响应确认 `expand.content` 是正文字符串，`expand.isContentEncrypted` 与 `expand.needFireMoney` 描述返回格式和当前权限。客户端核对章节与作品编号，仅接受明确未加密、当前价格为零的非空正文，保留文字中的字面量尖括号、实体和标点。未知格式或缺失权限字段拒绝作为正文显示，不尝试解密或自动购买。请求始终显式关闭 `autoOrder`。

没有 App 会话时，原有网页兼容阅读仍可通过官方网页会话取得授权图片，再由本机 Apple Vision 识别。App 账号请求失败不会静默切换到另一个网页账号。新 App 明文缓存使用格式版本 3；旧格式缓存按现有读取逻辑重新验证。

目录权限通过同账号的认证 App 请求读取。明确的 `has=true` 显示“已购买”；当前账号 `needFireMoney` 为有效数值零，或同一会话已成功读取正文时显示“可阅读”。真实对照确认同一章节在认证请求中为零价、匿名请求中为正价。零价也可能来自赠阅或活动，不能据此捏造购买交易。“可阅读”与“已购买”因此分别显示，只有明确未购状态才画锁；缺失或异常字段显示普通 VIP 标记。权限只保留在当前会话内，旧目录缓存和账号余额不作为购买证明。

VIP 图片解析参考上游 `src-tauri/ocr-worker/ocr_worker.py` 的多帧、38 像素行高、顶部 5 像素留白及拼音层处理。原生实现逐帧、分块识别，去除拼音注释区域并保留深色正文。直接把整张图片交给文字识别会混入拼音和背景，并可能丢失后续帧。新的缓存格式版本为 2，旧 VIP 缓存下次读取时重新获取并识别；更新失败时保留原文件并提示重试，不把旧乱码重新展示为正文。

## 每日签到

提交行为来自参考项目 [client.ts](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/3fa06a01db2a98585fa3abb77c4be9af0bcb856e/src/client/Sfacg/api/client.ts) 的 `newSign()`：`PUT /user/newSignInfo`，JSON 正文包含 `signDate`。该路径也出现在 APK 的明文协议字符串中。成功奖励采用参考类型中的 `name`、`num` 字段；服务器明确提示当天已签到时，不重复宣称获得奖励。

日期格式为北京时间 `YYYY-MM-DD`，依据历史版本中的 [getNowFormatDate](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/b508d2dae5df877f4f919b213b1881216e9da47a/src/client/utils/tools.ts)。不能使用设备所在时区替代。

无会话只读探测发现 `GET /user/newSignInfo` 返回 404，因此没有把提交地址直接当作查询地址。APK 中另有 `/user/signInfo`；它与 `/user/member/status` 的无会话 GET 请求均返回 401 和需要登录的提示。真实已签到账号的 `/user/signInfo` 返回成功信封及空数组；这不是损坏数据，也不证明当天尚未签到。日历数组未提供可靠状态时保留未知，不显示为“未签到”。明确的签到回执优先于可选详情查询，连续天数读取失败不会再覆盖已确认结果。已确认状态按经过哈希的 App 账号标识和北京时间日期缓存，换号与跨日不复用。签到只由用户按钮触发。

网页和 App 登录各自保有独立会话。会员与签到页面展示实际使用的账号昵称；不会把网页 Cookie 转换为 App 会话。普通菠萝包会员是否开通已经由 `expand.member.isOpen` 确认，会员有效期不依据含义不明的状态编号推算。

## 日常福利与会员礼包

日常福利的请求依据参考项目 [client.ts](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/3fa06a01db2a98585fa3abb77c4be9af0bcb856e/src/client/Sfacg/api/client.ts) 中 `getTasks`、`claimTask` 和 `taskBonus`，并与 APK `AccountApi` 注解及认证只读任务列表核对。`GET /user/tasks` 使用 `taskCategory=1`、`package`、当前安装标识 `deviceToken`、`page` 和 `size`；接受任务为 `POST /user/tasks/{taskID}`，领取已完成奖励为 `PUT` 同一路径。刷新列表不接受任务，也不领取奖励。

真实只读结果确认，已接受但尚未完成的任务也可能保持 `status=0`，须结合 `recordId`：编号为零才是未接受，正编号为进行中。只有已知任务类型、完整进度字段、`status=1` 且服务器完成数达到要求时才提供领奖动作；`status=2` 为已领取，异常或缺失状态保持未知。签到继续使用独立签到入口。每次用户手动操作前重新获取状态，按服务器明确回执确认结果，不自动重试提交。本项目不伪造阅读时长、分享访问、广告观看、充值或订阅完成，也不调用这些任务完成上报接口。

会员礼包由 APK `WelfareApi` 的真实方法/参数注解确认：列表为 `GET /Member/Prize`，可带 `packType` 查询参数；领取为 `POST /Member/Prize?type={type}&packType={packType}`，参数位于 URL 查询中，没有 JSON 或表单正文。本版支持普通菠萝包会员 `packType=0` 的四类已确认礼包。官方[会员权益说明](https://pages.sfacg.com/h5/app/common/guide/membership-program.html)及其公开脚本说明了日礼包与每七天礼包；实际名称、数量说明、间隔和剩余天数仍以服务器列表为准。

礼包列表即使未登录也可能返回，因此 `num=0` 或 `residueDay=0` 单独不能证明可领取。客户端先通过 `GET /user?expand=member,dianyamember` 确认 App 身份和真正布尔值 `member.isOpen`，再读取礼包列表。认证只读验证确认 `interval`、`residueDay`、`lastCreateDateTime` 与账号的日/周冷却一致；仅当前会员资格明确有效、已知礼包类型且冷却为零时允许用户手动提交。`/Member/Prize/Summary` 的汇总字段不用于推断会员资格；缺失字段、未知礼包或冷却异常不启用领取。提交前重新检查身份、资格和冷却，使用并发互斥及会话代际校验，服务器明确成功后才显示领取成功，不臆测回执未提供的奖励数量。此次实现验证未提交真实会员礼包领取。

## 云端阅读位置

App 的 `GET /user/NovelViews` 返回 `accountId`、`novelId`、`chapterId`、`lastViewTime` 和 `unreadChapCount`，已通过认证只读验证。APK `NovelApi.updateNovelVisits` 注解确认写入为 `PUT /user/NovelViews/{novelId}`，作品编号是路径参数，正文为 JSON 对象。原始调用指令进一步确认键 `chapterId` 和布尔键 `triggerCardPieceDrop`。本项目只提交实际打开的章节，并显式设置 `triggerCardPieceDrop=false`，关闭附带的卡片掉落动作。该 App 写入路径已验证请求构造，未为测试修改真实账号进度。

没有 App 会话时保留官方移动网页兼容路径：`POST https://m.sfacg.com/API/Book.ashx?op=addviewrecord`，表单字段为 `bookid` 与 `articleid`。此前保持原章节编号不变的验证显示，Web 提交后 App 阅读记录的服务器时间更新，确认两条读取/写入路径使用同一阅读记录。存在 App 会话时始终使用 App 主账号，不要求可选网页会话有效。

客户端在正文成功显示 3 秒、仍处于该章节且应用位于前台时提交章节；滚动、下载、导入与打开书库不提交旧进度。请求和结果校验会话代际，App 读取时核对记录的账号 ID，写入前重新确认当前 App 身份。云端同步精确到章节，段落位置保存在本机；不同章节由读者点击“从云端继续”选择，不自动覆盖本机位置。

真实 `lastViewTime` 为不带时区的 ISO 日期，客户端不擅自假定其时区，也不用它覆盖本机较新的进度。`m.sfacg.com/history/` 与 `getViewHistorys` 只包含书籍访问记录，不作为章节位置；`pages.sfacg.com/api/user/NovelViews` 实际返回用户资料，未使用。
