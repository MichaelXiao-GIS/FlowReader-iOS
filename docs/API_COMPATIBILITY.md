# 账号接口兼容记录

核对日期：2026-11-07（本次补充登录与 WebView 会话核对；其他接口沿用 2026-11-01 记录）。此记录描述兼容实现的证据，不代表 SFACG 提供公开、稳定的开发者 API。

## 参考材料

- [SFNovel-ReaderProject](https://github.com/Mios-dream/SFNovel-ReaderProject/tree/3fa06a01db2a98585fa3abb77c4be9af0bcb856e)：网页账号、书架、VIP 等级、已订阅章节与 App 请求协议。
- 用户提供的 Android 安装包：`com.sfacg`，版本 `5.2.84`，版本号 `5284`。SHA-256：`c2ed6f5df7fe9dc82c98ac59579b3e19bfd68e51c2570c14d13da65475efcb10`。
- APK 带有 Secneo 包装。本轮从保留的数据中恢复了部分 DEX 字符串表、类型表、方法表及 Retrofit 方法/参数注解，并在附加代码区确认了部分原始调用的参数构造。业务代码没有完整还原；以下分别注明注解、实际调用、官方网页和只读响应提供的证据，路径字符串本身不作为请求方法已经确认的证据。
- APK、提取资源、反编译文件和真实账号响应均不进入仓库与发行包。客户端协议由本项目以 Swift 独立实现。

## 主要账号与 App 书架

### 2026-11-07：统一日常登录与安卓证据

对上述同一 APK 重新提取被包装 DEX 的映射表、方法及 Retrofit 注解，并核对附加区保留的原始指令。`AccountApi.login(Map<String,Object>)` 声明 `POST /sessions`，参数为请求 body；`getUser(String)` 声明 `GET /user?expand=…`；`NovelApi.getChaps(long,String,boolean)` 声明 `GET /Chaps/{id}`，参数为 `id`、`expand`、`autoOrder`。HTTP 动词通过 APK 内 Retrofit 注解解析器 `qf0.t$a.e(Annotation)` 的原始分支确认：`uf0.f` 对应 GET、`uf0.o` 对应 POST，非仅根据路径字符串推测。

安卓 CookieJar 实现 `lu.a` 将响应 Cookie 写入 `SharedPrefsCookiePersistent`，请求时按有效期与 URL 匹配复用。其 `h()` 方法遍历已保存 Cookie，找到 `.SFCommunity` 后调用 `b(Cookie)`；后者设置 WebView CookieManager，将 Cookie 写入 `sfacg.com` 并同步。因此，所检查实现存在将已有登录会话共享给内嵌网页的机制，无需在该同步方法里再次输入密码。`h()` 与 Retrofit 解析方法的壳内主体已被替换；恢复关联依据为附加原始 code_item 与当前方法完全匹配的 16 字节头，以及字段、方法、字符串和分支指令一致性。未完整追踪每个网页生命周期的调用时机，不声称已完整反编译。

本项目的 `content(chapter:)` 在已保存 App 登录时本来就优先请求 App 正文，且请求固定 `autoOrder=false`；无需先取得网页会话。此前“我的”与会员页并列展示网页授权，加上未登录 VIP 阅读提示“官方网页登录”，造成了需要第二次登录的误导。本次统一日常入口为“登录菠萝包”，移除账户余额区的重复登录按钮；旧网页功能收纳到“我的 → 兼容设置”。会员页存在 App 会话时不再查询旧网页身份，书库和未登录 VIP 阅读也统一引导主账号登录。

本次不自动复制或转换 App / Web 凭据，不把 `session_APP` 改名成 `session_PC`。安卓同步 `.SFCommunity` 的代码证据不能证明目前所有网页接口接受仅该 Cookie；现有网页兼容验证还要求 `session_PC`。旧会话继续独立保留，App 登录失效不会切换到另一网页账号。真实账号登录、验证码、服务端 Cookie 返回与网页免登录互通均未在本次重新实测。

本地分析证据位于被 Git 忽略的 `build/login-audit-20261107/`：`android-login-findings.txt`、`login-focused-annotations.json`、`login-cookie-bytecode.json`。这些文件来自用户 APK，未读取真实会话或发起网络登录；提取代码与 APK 不进入发行包。

已连接 App 账号服务时，书架、云端续读、正文和福利使用该 App 账号。网页会话是独立的可选兼容入口；过期网页会话不会阻断有效 App 账号，也不会以另一个网页账号替代 App 书架。保存有 Cookie 只代表存在会话材料，只有当前身份查询成功才显示连接已确认。会话切换会清除旧账号的云端缓存和内存权限；暂时查询失败后仍保留上一次已验证身份用于后续比较，防止不同账号的部分书架合并。

APK `com.sf.model.Account` 的头像字段为字符串 `avatar`，`getAvatar()` 原样返回；`HomeLayout` 将此值交给图片加载器显示在圆形头像中。没有发现需改用 `avatarImage` 或拼接头像域名的依据。本项目让账号、钱包和会员礼包资料共用头像 URL 解析，保留 HTTPS、协议相对地址及已有网页字段兼容；缺失或非法地址保持无头像，不影响身份验证或伪造头像地址。

APK `PocketApi` 的方法注解和 `ShelfViewModel` 调用确认 `GET /user/Pockets?expand=novels,comics,albums,latestchapter`，该方法没有分页参数。`Pocket.build` 的类别映射为漫画 1、文字小说 2、有声 3、对话小说 4。本项目读取文字小说分类的 `expand.novels`，保留分类名，按作品编号去重，并从 `authorName` 等字段读取作者和作品资料。当前认证只读验证已确认完整分类、作者和小说集合可用；每个分类的 `accountId` 必须匹配本次 App 身份。异常分类保留部分同步提示，全部异常不会显示为已确认空书架。

## 网页兼容书架的 HTTP 500

参考实现 `src-tauri/src/adapters/sfacg/web/catalog.rs` 明确说明，网页端的有声、视频收藏分类可能返回 HTTP 500。参考实现跳过这些分类及失败的后续分页，保留其他分类的结果。

旧版 Swift 实现把任何一个分类失败视为整次同步失败，账号页随后又显示空书架。本版按分类隔离失败，返回可读取作品和部分同步提示。全部分类失败、目录请求失败、会话失效仍显示错误；取消请求不作为网络故障显示。没有真实请求记录时，不能仅凭截图确定具体哪一个分类返回了 500。

同一书架页面在携带账号 Cookie 时可能返回不含作者的精简卡片，而公开页面包含作者链接。遇到缺失作者的页面时，客户端以无 Cookie 请求读取同一公开页面，只按作品 ID 补全作者；保留账号请求得到的书籍、标题和分类。公开信息不可读时不会丢弃账号书架，也不会猜测作者。此方式按页补全，避免为每本书单独请求详情。

## VIP 资料与章节权限

网页 VIP 资料使用参考实现中的 `pages.sfacg.com/api/User?expand=newVip`，依据 `newVip.isNewVip` 选择新 VIP 等级或 `api/common/vipInfo` 的旧 VIP 等级。App 用户资料的 expand 列表包含 `vipInfo,newVip,member,dianyamember`，也见于所提供 APK。

VIP 等级、付费会员资格和单章订阅权限是不同概念。只显示已经确认含义的服务器字段，缺失状态不推断为已开通或未开通。已连接 App 账号时，正文使用 `GET /Chaps/{chapterID}?expand=content&autoOrder=false`。`expand.content` 是 App 传输正文，`isContentEncrypted=false` 仍含单字置换，不能直接视为明文。1.2.0–1.3.0 漏掉此步骤；1.4.0 在核对章节/作品编号、明确未加密、当前价格为零后，使用上游 `sfacg-content-dictionary.json` 的 3760 条映射逐 Unicode scalar 单次还原。算法见 `adapters/storage/settings.rs::decode_api_content`，免费章与 VIP 章都需要处理。仅处理服务端已经授权的内容，不处理未知加密格式；标点、空白、emoji、字面量 HTML 与实体保留。请求始终显式关闭 `autoOrder`。

没有 App 会话时，原有网页兼容阅读仍可通过官方网页会话取得授权图片，再由本机 Apple Vision 识别。App 账号请求失败不会静默切换到另一个网页账号。已还原 App 正文使用格式版本 4。仅标记为 3 的正编号 App 章节缓存本地转换一次，原子保存成功后才返回；免费章、VIP、下载重跑及导出都经过此入口。网页图片识别版本 2、本地导入和版本 4 不重复还原，失败保留旧文件并明确报错。

目录权限通过同账号的认证 App 请求读取。1.5.0 同时接入 APK `AccountApi.getUserConsumesDetail` 和订阅详情 `ConsSubscriptionDetailViewModel.j2` 使用的 `GET /user/consumes?type=chaps&entityId={novelId}&page={page}&size={size}`。原始调用确认 `type=chaps` 和作品编号；`ConsSubscriptionDetailItemViewModel` 的小说阅读跳转确认 `detailId` 是章节编号。认证只读验证确认数组结构、记录与目录的对应关系及每页最多 20 条的限制。目录先给出当前权限，随后每页逐步补齐已购标记；按会话和作品缓存，未完成分页不会冒充完整记录。仅本书、目录中存在、明确为“小说订阅”、火券或代券支出为正且不是广告解锁的记录可标记为“已购买”；广告和零消耗不推断成付费。分页失败保留已经确认的记录并提示重试，不把缺失记录判断成未购买。历史付费与当前明确收费权限冲突时，保留当前权限并提示差异。

明确的 `has=true` 显示“已购买”；当前账号 `needFireMoney` 为有效数值零，或同一会话已成功读取正文时显示“可阅读”；有效正价且缺失 `has` 时显示“需订阅”。APK 的 `Chapter` 模型没有 `has/owned/purchased` 字段，目录调用中的 `expand=originNeedFireMoney` 提供原价，不能作为购买记录。零价也可能来自赠阅或活动，不能据此捏造购买交易。“可阅读”“需订阅”与“已购买”分别显示；缺失或异常价格字段保持未知。权限只保留在当前会话内，旧目录缓存和账号余额不作为购买证明。

## 余额与单章订阅

- APK `AccountApi.getUserMoney`：`GET /user/money`，`fireMoneyRemain` 为火券，`couponsRemain` 为代券。`GET /user?expand=welfareCoin` 的 `expand.welfareCoin` 为金币。三者使用整数原值，缺失或非法值不显示为零。实际 money 响应不含 `accountId`；通过相同会话及请求前后的 `/user` 身份绑定，若响应带编号则必须匹配。
- APK 内置说明确认火券、代券可合计自动结算；金币不能计入章节订阅余额。不假定代券、火券的具体扣减顺序，不自行换算人民币。
- APK `NovelApi.orderNovelChaps` 和上游 `src/client/Sfacg/api/client.ts` 均确认 `POST /novels/{id}/orderedchaps`。单章 JSON 为 `chapIds: [chapterID]`、`orderAll: false`、`autoOrder: false`、`orderType: "readOrder"`。不传没有证据的 `useCoupon`，不自动选择额外优惠券，不开启整书或后续章节自动订阅。
- 先从认证目录读取当前报价，绑定章节、作品、账号、会话及有效期；用户明确确认后重新读取身份、价格与余额。已可阅读则不下单，价格变化要求重新确认，未知或不足余额不提交。
- 单账号提交串行、确认凭据仅用一次。发送前持久记录待确认订单；超时、取消后可能已发出、服务器异常或含糊回执都不自动重试，重新打开或重启也不重复下单。只有只读确认可阅读后才清除待确认标记；确定未发出的请求或明确拒绝可解除标记。购买状态以服务器回读为准。
- 实际扣款不作为自动化或真实账号验证的一部分；购买提交、拒绝、重复点击与不确定结果使用注入测试验证。真实账号仅用于读取余额、报价、权限与已授权正文。

VIP 图片解析参考上游 `src-tauri/ocr-worker/ocr_worker.py` 的多帧、38 像素行高、顶部 5 像素留白及拼音层处理。原生实现逐帧、分块识别，去除拼音注释区域并保留深色正文。直接把整张图片交给文字识别会混入拼音和背景，并可能丢失后续帧。该网页识别路径采用缓存格式版本 2，更早的网页 VIP 缓存下次读取时重新获取并识别；更新失败时保留原文件并提示重试，不把旧乱码重新展示为正文。

## 每日签到

提交行为来自参考项目 [client.ts](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/3fa06a01db2a98585fa3abb77c4be9af0bcb856e/src/client/Sfacg/api/client.ts) 的 `newSign()`：`PUT /user/newSignInfo`，JSON 正文包含 `signDate`。该路径也出现在 APK 的明文协议字符串中。成功奖励采用参考类型中的 `name`、`num` 字段；服务器明确提示当天已签到时，不重复宣称获得奖励。

日期格式为北京时间 `YYYY-MM-DD`，依据历史版本中的 [getNowFormatDate](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/b508d2dae5df877f4f919b213b1881216e9da47a/src/client/utils/tools.ts)。不能使用设备所在时区替代。

无会话只读探测发现 `GET /user/newSignInfo` 返回 404，因此没有把提交地址直接当作查询地址。APK 中另有 `/user/signInfo`；它与 `/user/member/status` 的无会话 GET 请求均返回 401 和需要登录的提示。真实已签到账号的 `/user/signInfo` 返回成功信封及空数组；这不是损坏数据，也不证明当天尚未签到。日历数组未提供可靠状态时保留未知，不显示为“未签到”。明确的签到回执优先于可选详情查询，连续天数读取失败不会再覆盖已确认结果。已确认状态按经过哈希的 App 账号标识和北京时间日期缓存，换号与跨日不复用。签到只由用户按钮触发。

网页和 App 登录各自保有独立会话。会员与签到页面展示实际使用的账号昵称；不会把网页 Cookie 转换为 App 会话。普通菠萝包会员是否开通已经由 `expand.member.isOpen` 确认，会员有效期不依据含义不明的状态编号推算。

## 日常福利与会员礼包

日常福利的请求依据参考项目 [client.ts](https://github.com/Mios-dream/SFNovel-ReaderProject/blob/3fa06a01db2a98585fa3abb77c4be9af0bcb856e/src/client/Sfacg/api/client.ts) 中 `getTasks`、`claimTask` 和 `taskBonus`，并与 APK `AccountApi` 注解及认证只读任务列表核对。`GET /user/tasks` 使用 `taskCategory=1`、`package`、当前安装标识 `deviceToken`、`page` 和 `size`；接受任务为 `POST /user/tasks/{taskID}`，领取已完成奖励为 `PUT` 同一路径。刷新列表不接受任务，也不领取奖励。

真实只读结果确认，已接受但尚未完成的任务也可能保持 `status=0`，须结合 `recordId`：编号为零才是未接受，正编号为进行中。只有已知任务类型、完整进度字段、`status=1` 且服务器完成数达到要求时才提供领奖动作；`status=2` 为已领取，异常或缺失状态保持未知。签到继续使用独立签到入口。每次用户手动操作前重新获取状态，按服务器明确回执确认结果，不自动重试提交。本项目不伪造阅读时长、分享访问、广告观看、充值或订阅完成；真实小说阅读时长由独立协议上报，其余条件不自动模拟。

会员礼包由 APK `WelfareApi` 的真实方法/参数注解确认：列表为 `GET /Member/Prize`，可带 `packType` 查询参数；领取为 `POST /Member/Prize?type={type}&packType={packType}`，参数位于 URL 查询中，没有 JSON 或表单正文。本版支持普通菠萝包会员 `packType=0` 的四类已确认礼包。官方[会员权益说明](https://pages.sfacg.com/h5/app/common/guide/membership-program.html)及其公开脚本说明了日礼包与每七天礼包；实际名称、数量说明、间隔和剩余天数仍以服务器列表为准。

礼包列表即使未登录也可能返回，因此 `num=0` 或 `residueDay=0` 单独不能证明可领取。客户端先通过 `GET /user?expand=member,dianyamember` 确认 App 身份和真正布尔值 `member.isOpen`，再读取礼包列表。认证只读验证确认 `interval`、`residueDay`、`lastCreateDateTime` 与账号的日/周冷却一致。

APK 礼包模型 `aw.y.g(JSONObject)` 以 `optLong("residueDay")` 读取有符号剩余天数，`f()` 返回该值。`SFMemberGiftPackAdapter.b` 原始指令在 `0x8656d62` 调用 `f()`，`0x8656d72` 的 `if-lez` 跳入“立即领取”并启用按钮；正数 1 显示“明日再来”，其他正数显示剩余天数并禁用按钮。`interval` 独立保存，不参与这个资格判断。因此本项目在当前会员资格明确有效、已知礼包类型的前提下，以有效整数 `residueDay <= 0` 允许手动领取，不再把负数误判为未知，也不额外要求 `interval > 0`。缺失、布尔值和小数仍保持未知；有效正数 `interval` 仅作为周期元数据，未知周期不猜测本地领取确认记录的释放时间。

`/Member/Prize/Summary` 的汇总字段不用于推断会员资格；未知礼包或无法解析的冷却值不启用领取。提交前重新检查身份、资格和冷却，使用并发互斥及会话代际校验，服务器明确成功后才显示领取成功，不臆测回执未提供的奖励数量。此次实现验证未提交真实会员礼包领取。

## 小说阅读时长（1.6.0）

APK `CommonApi.updateReadingTime` 的 Retrofit 注解确认 `PUT /user/readingtime`，请求为 JSON `@Body`。调用 `lw.aa.E0` 的原始指令（`0x869fb76`–`0x869fbec`）构造 `seconds`、`readingDate`、`entityType`、`entityId`、`chapterId` 五字段。小说分支 `lw.qf` 在 `0x86141ce`/`0x86141d6` 分别读取 `getNovelSeconds` 与 `getNovelSubmitSeconds` 后相减，`0x8614232` 的小说类型常量为 2。成功回调才把本次增量加入已提交秒数，证明 `seconds` 是增量秒数；并非累计日总量。该计时管理器的日期格式明确为 `yyyy-MM-dd`、`GMT+08`。

客户端只在账号身份确认后、正编号小说的正文实际显示且应用 active 时启动单调时钟；加载、排版、错误、目录、设置、书签、购买弹层和后台均暂停。正文点触、滚动和翻页更新活动时间，连续 120 秒无活动截止计时，触摸恢复不会补算空档。APK 同样存在两分钟无活动停止路径。跨章尾段保留各章归属；跨北京时间午夜切成两日，秒数来自实际 elapsed，不按定时器回调次数累加。负编号导入/演示内容及自动朗读播放时不计时，避免语音自动换章反复重启空闲窗口。

本应用每 5 秒检查一次，累计约 60 秒提交，离开正文时提交整数尾段。这是本机批量策略；APK 定期检查中的实际时间阈值为 300 秒（相关日志文字并不准确），接口本身没有以此限制请求最小秒数。请求绑定已验证账号、当前会话代次和真实书章编号；发出前再验证身份。协议没有幂等字段，因此每段取走后只尝试一次：超时、发出后取消、异常信封均不自动重放，不将旧账号剩余时间转给新账号。未确认或未发出的时长可能少记；计时不跨进程续算，也不承诺后台网络一定完成。

上报成功仅触发福利列表重新读取，不把本机时长叠加到服务器任务进度，也不自动接任务或领奖。仅明确完成的服务端任务可手动领取奖励。使用 `systemUptime` 只计算本应用内事件的经过时间，隐私清单按 [Apple 的 35F9.1 用途](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) 声明；请求不发送系统启动时间或原始单调时间戳。

验证使用注入时钟、离线身份与本地请求接收器。端到端离线场景使用真实前台经过时间，确认阅读后服务器模拟进度由 59/60 到可领取，以及不确定回执仍保持不可领取；这些不是官方服务的真实入账或领奖验证。

## 云端阅读位置

App 的 `GET /user/NovelViews?withUnreadCount=true` 返回 `accountId`、`novelId`、`chapterId`、`lastViewTime` 和 `unreadChapCount`，已通过认证只读验证。APK `NovelApi.updateNovelVisits` 注解确认写入为 `PUT /user/NovelViews/{novelId}`，作品编号是路径参数，正文为 JSON 对象。原始调用指令进一步确认键 `chapterId` 和布尔键 `triggerCardPieceDrop`。本项目只提交实际打开的章节，并显式设置 `triggerCardPieceDrop=false`，关闭附带的卡片掉落动作。该 App 写入路径已验证请求构造，未为测试修改真实账号进度。

没有 App 会话时保留官方移动网页兼容路径：`POST https://m.sfacg.com/API/Book.ashx?op=addviewrecord`，表单字段为 `bookid` 与 `articleid`。此前保持原章节编号不变的验证显示，Web 提交后 App 阅读记录的服务器时间更新，确认两条读取/写入路径使用同一阅读记录。存在 App 会话时始终使用 App 主账号，不要求可选网页会话有效。

客户端在正文成功显示 3 秒、仍处于该章节且应用位于前台时提交章节；滚动、下载、导入与打开书库不提交旧进度。请求和结果校验会话代际，App 读取时核对记录的账号 ID，写入前重新确认当前 App 身份。云端同步精确到章节，段落位置保存在本机；不同章节由读者点击“从云端继续”选择，不自动覆盖本机位置。

真实 `lastViewTime` 为不带时区的 ISO 日期。APK `NovelViews.build` 调用的 `u70.u.M` 对长度 19 的日期追加 `+0800`，再用 `yyyy-MM-dd'T'HH:mm:ssZ` 解析；1.5.0 依据这一实际指令将此格式按北京时间解析，并兼容显式时区，按最近阅读降序排列。没有有效阅读记录的书籍保留稳定书架顺序。

书架响应没有章节总数；百分比通过按需读取目录、定位云端 `chapterId` 的目录序号得到，按章节计算，不声称是字数或段落精度。未知或目录不存在的位置不显示虚构的 0%；读取进度不提交云端写入。目录读取限制并发并复用缓存，避免一次载入整个书架的所有目录。

`m.sfacg.com/history/` 与 `getViewHistorys` 只包含书籍访问记录，不作为章节位置；`pages.sfacg.com/api/user/NovelViews` 实际返回用户资料，未使用。

## 阅读目录定位与排列

1.5.1 的阅读目录参考 APK 小说目录的已确认行为：`CategoryViewModel.K0` 按 `chapId` 匹配正在阅读的章节，保存包含分卷标题的列表位置并高亮；`CategoryFragment.X1` 使用该位置定位列表，目录刷新后也会重新定位。分卷依据 `volumeId`，不按可能重复的标题合并。资源中的 `location_goto` 文案为“去当前”。本项目以 SwiftUI 原生列表实现打开时定位和“回到当前章节”。

正序／倒序是本轮用户要求新增的呈现选项：反转卷顺序及卷内章节，不修改阅读器的自然章节顺序或云端进度。已在 APK 找到正／倒序资源，但明确调用点来自漫画缓存目录，不将其作为小说目录现有按钮的证据。

阅读目录自身也会调用既有 `chapterPurchaseStates` 查询，覆盖冷启动直接恢复阅读、未经过作品详情页的路径。查询复用同账号缓存，按当前账号代次接收权限与订阅记录的增量结果；关闭目录的取消或临时失败不清除已确认状态。此入口不提交购买或云端阅读进度。

## 作者资料与作品（1.7.0）

APK `AuthorApi.getAuthorInfo(long,String)` / `getAuthorNovels(long)` 的注解确认 `GET /authors?authorId={id}&expand=fansNum` 与 `GET /authors/{id}/novels`。小说作品接口直接返回完整数组，没有漫画接口的分页参数；保留服务器顺序，不猜测最新排序。小说资料的根 `authorId` 保存为可选字段，旧书库和下载索引可继续读取。

作者资料确认字段为 `authorId`、`accountId`、`authorName`、`avatar`、`introduce` 和 `userInfo.expand.fansNum`。严格区分作者编号与账号编号：APK 的作者头像点击实际通过 `NovelDetailAuthorItemViewModel` 的 `accountId` 打开含社交内容的个人主页；本版本用独立作者接口呈现公开资料与小说作品，不把账号编号或昵称推断成作者编号，不增加关注、私信、动态等社交写操作。

匿名只读验证三位作者与 15 本作品，所有作品行均包含对应作者编号和名称。请求不携带读者 Cookie；无需会员或重新登录。头像复用降采样与有限缓存，资料和作品独立加载、独立重试，取消和晚到请求不覆盖新数据，刷新失败保留已有内容。未取得真实空作品作者样本，空数组处理由离线测试覆盖。
