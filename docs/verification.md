# TiebaPure Verification

Last updated: 2026-07-25 (Asia/Shanghai)

> 本地构建、模拟器功能、匿名线上冒烟、隐私清单、IPA 与实际暂存树门禁已通过。远端发布状态以[当前 `main` 的 iOS CI](https://github.com/infinityf4p/TiebaPure-iOS/actions/workflows/ci.yml?query=branch%3Amain)为准；工作流未全绿时不得交付。

## 固定环境

- macOS 26.5.2 (`25F84`)
- Xcode 26.1.1 (`17B100`)
- XcodeGen 2.45.4
- iOS Simulator 26.1 (`23B86`)
- SwiftProtobuf 1.38.1
- Deployment target: iOS 18.0

模拟器 XCTest 必须按正常方式签名运行。不要为模拟器测试传入 `CODE_SIGNING_ALLOWED=NO`，否则 Keychain 回归测试会因为缺少 entitlement 而失去验证意义。

## 测试清单与条件跳过

- 单元测试：202 项。
  - 201 项离线确定性测试。
  - 1 项 opt-in 匿名线上冒烟；普通本地测试和 CI 默认跳过。
- CI 固定 fixture UI 测试清单：48 项。
  - 2 项刷新功能测试覆盖下拉与首页 Tab 重选，不依赖动画状态。
  - 1 项空态下拉刷新测试。
- 2 项图片页测试覆盖捏合/双击缩放、保存反馈、单击返回来源页，以及拒绝中间/边缘右划和下划退出。
  - 4 项主页图片测试覆盖预览返回、离屏滚动复用、返回完成同一显示周期立即滚动的逐帧对齐，以及 0.5 秒内首次点击另一张图。
  - 1 项浏览历史测试覆盖成功浏览后记录、“我的”入口和重新打开帖子。
  - 2 项本机帖子库测试覆盖收藏、收藏列表重新打开、阅读位置提示和目标楼层定位。
  - 1 项外观测试覆盖访客设置入口、跟随系统、浅色/深色即时切换及重启持久化。
  - 1 项长文本测试覆盖主贴、评论、楼中楼预览与完整楼中楼页面。
  - 1 项原生文本复制测试覆盖帖子详情长按选中与系统复制菜单。
  - 1 项动画抑制测试仅在 Reduce Motion 开启时运行。
  - 2 项仅在 iPad 运行。

UI 测试使用 `UITEST_USE_FIXTURES`，不访问贴吧线上服务。夹具场景为 `success`、`refreshUpdate`、`emptyThenSuccess`、`empty`、`error`、`expired`、`slow`、`paginationFailure`、`longContent`、`subpostReference` 和 `imageGesture`。

为规避 XCUITest 在多次应用重启后偶发的 Accessibility snapshot 查询超时，完整 UI 验收使用四个独立的 `xcodebuild` invocation：

1. 单独运行 `testHomeTabReselectAfterScrollingRefreshesContent`。
2. 运行 UI shard A。
3. 运行 UI shard B。
4. 运行 UI shard C。

每轮 CI 聚合必须恰好覆盖固定清单的全部 48 项，不能把基础设施超时计作通过，也不能遗漏测试。普通 CI 同样只运行确定性 fixture 分片。

## iPhone 17 下拉刷新完整回归

设备：iPhone 17 / iOS 26.1 (`23B86`)

`v1.0.2 (6)` 发布前最终聚合使用正常模拟器签名一次运行完整测试树：**171 通过 / 4 条件跳过 / 0 失败**，共 175 项。其中单元测试 137 通过、1 项匿名线上冒烟按设计跳过；UI 测试 34 通过、3 项设备/辅助功能条件测试按设计跳过。验证码登录兼容、成功回调不渲染、`window.open` 外部 App 拦截和账号保存均包含确定性回归。

| 轮次 | 单元测试 | UI 测试 | 结果 |
| --- | --- | --- | --- |
| 1 | 106 通过 / 1 条件跳过 / 0 失败 | 22 通过 / 3 条件跳过 / 0 失败 | PASS |
| 2 | 106 通过 / 1 条件跳过 / 0 失败 | 22 通过 / 3 条件跳过 / 0 失败 | PASS |

以上完整 UI 轮次覆盖加入图片下载回归前的 25 项测试树。单元测试唯一跳过项是 opt-in 匿名线上冒烟；UI 的三个预期跳过项是 Reduce Motion-only 测试和两个 iPad-only 测试。

随后加入图片页单击返回与保存原图功能，并在同一台 iPhone 17 / iOS 26.1 模拟器完成：

- 图片功能阶段单元测试：109 通过 / 1 条件跳过 / 0 失败。
- 图片页与三条刷新路径定向 UI 回归：4 通过 / 0 跳过 / 0 失败。
- 保存成功反馈与单击返回最终复测：1 通过 / 0 跳过 / 0 失败。

帖子正文截断修复后，在同一模拟器继续完成：

- 最终单元测试：110 通过 / 1 条件跳过 / 0 失败。
- 主贴、评论及两种楼中楼长文本高度回归：1 通过 / 0 跳过 / 0 失败。
- HTTPS 链接 trait 与长图入口回归：2 通过 / 0 跳过 / 0 失败。

随后进行追加安全与健壮性审查，修复持久化 Cookie 值注入、取消保存时恢复不安全旧凭证、媒体初始 URL 绕过、下载图片像素与文件名边界、超范围帖子 ID、定位楼层后的分页推进，以及 FRS/搜索错误码不一致。最终在同一台 iPhone 17 / iOS 26.1 模拟器完成：

- 完整离线单元测试：119 通过 / 0 跳过 / 0 失败。
- 下拉刷新、图片保存/单击返回、长正文/楼中楼和 HTTPS 链接关键 UI 回归：5 通过 / 0 跳过 / 0 失败。
- `xcodebuild analyze`：PASS。
- Release `iphoneos` unsigned build：PASS。

帖子浏览历史加入后，在同一台 iPhone 17 / iOS 26.1 模拟器追加完成：

- 完整单元测试：139 通过 / 1 条件跳过 / 0 失败，共 140 项。
- 新增 CI shard C：11 通过 / 0 跳过 / 0 失败。
- 浏览历史端到端路径连续运行 3 次均通过，覆盖成功打开帖子后记录、“我的”入口、历史列表与重新打开帖子。
- “进吧”及“我的”原有访客入口回归：1 通过 / 0 跳过 / 0 失败。
- Release `iphoneos` unsigned build：PASS。

本机帖子收藏与阅读位置加入后，在同一台 iPhone 17 / iOS 26.1 模拟器追加完成：

- 完整单元测试：141 通过 / 1 条件跳过 / 0 失败，共 142 项。
- 收藏与“继续上次阅读”两条新增 UI 路径各完成 2 次通过；确定性夹具覆盖本机持久化、收藏列表重新打开及定位 2 楼。
- 帖子右滑、图片区域右滑、短距下拉刷新、长正文和原有浏览历史等风险相关 UI 回归：7 通过 / 0 跳过 / 0 失败。
- 当前 CI shard C 为 15 项，完整 fixture UI 测试树为 42 项；本次未发布的本地变更未重复执行完整 42 项矩阵。
- `xcodebuild analyze`：PASS。
- Release `iphoneos` unsigned build 及隐私清单入包校验：PASS。
- XcodeGen 重新生成结果与仓库内唯一工程一致：PASS。

外观设置加入后，在同一台 iPhone 17 / iOS 26.1 模拟器完成：

- 最终离线单元测试：142 通过 / 0 跳过 / 0 失败；另有 1 项 opt-in 匿名线上冒烟未在本轮运行。
- 外观 UI 路径分别在系统浅色与系统深色环境运行，2 / 2 通过；覆盖访客入口、强制深色、强制浅色、重启后保持和恢复跟随系统。
- 深色设置页合成夹具截图已人工检查，未发现截断、溢出或对比度异常。
- `xcodebuild analyze`：PASS，无警告。
- Release `iphoneos` unsigned build 及隐私清单入包校验：PASS。
- XcodeGen 连续重新生成的工程 SHA-256 一致：PASS。

帖子详情文本复制加入后，在同一台 iPhone 17 / iOS 26.1 模拟器完成：

- 文本选择策略、现有多段表单与签名基础组件：5 通过 / 0 跳过 / 0 失败。
- 主贴正文长按调出系统复制菜单并执行复制：1 通过 / 0 跳过 / 0 失败。
- HTTPS 链接、帖子右滑、楼中楼右滑、短距下拉刷新及长文本布局风险回归：5 通过 / 0 跳过 / 0 失败。

## iOS 18 系统图片转场专项回归

最低系统版本提升到 iOS 18.0 后，图片详情曾改用 UIKit `UIViewController.Transition.zoom`。后续单路径自定义转场已取代该阶段实现，最终架构与结果见下方专项回归。

设备：iPhone 17 / iOS 26.1 (`23B86`)

- 完整单元测试：174 通过 / 1 条件跳过 / 0 失败，共 175 项。
- 根页面与两条图片转场定向 UI 回归：3 通过 / 0 跳过 / 0 失败。
- 两条图片转场 UI 回归连续重复三轮：6 次执行全部通过；覆盖再次打开、捏合/双击缩放、保存、点击退出、关闭按钮退出及裁剪缩略图比例变化。
- 对模拟器录屏 4.5–10.0 秒的打开与关闭转场按 60 Hz 取样，最低可见像素占比为 35.675%，未检测到近黑帧。
- Release `iphoneos` unsigned archive：PASS；包内 `MinimumOSVersion` 为 18.0，包含可解析的隐私清单且不含签名或描述文件。

图片缩放跟手性及主页返回滚动错位修复后，继续完成：

- 全屏缩放只在“未缩放/已缩放”状态切换时通知外层，不再每帧跨 SwiftUI 更新；重复的 `contentInset` 和无障碍百分比写入也已合并。
- SwiftUI 长期负责列表缩略图显示，UIKit 来源图只在系统打开/关闭转场期间接管，转场结束立即恢复，避免离屏滚动复用后显示错位。
- 完整单元测试：175 通过 / 1 条件跳过 / 0 失败，共 176 项。
- 主页图片像素对齐、全屏缩放和重复打开三条 UI 回归连续三轮：9 次执行全部通过；另有四条图片风险回归 4 / 4 通过。
- 新增主页图片回归会在预览返回后滚动至离屏再返回，比较前后尺寸与采样像素，并验证图片可以再次从当前位置打开。
- 最终录屏 28–37 秒转场区间按 60 Hz 取样，最低可见像素占比为 35.951%，近黑帧为 0；关键帧人工检查未发现错位或留影。
- `xcodebuild analyze`、Release `iphoneos` unsigned archive、隐私清单及未签名结构校验：PASS。

点赞数单行与右对齐修复后，继续完成：

- 显示规则固定为三位数原样、四位数 `k`、五位及以上 `w`，后两种保留一位小数；格式边界单元测试通过。
- 完整离线单元测试：176 通过 / 0 跳过 / 0 失败；opt-in 匿名线上冒烟未在本轮运行。
- iPhone 17 上主贴、回复、楼中楼大点赞数布局与现有点赞交互、等级单行、Accessibility XXXL 回归：4 / 4 通过。
- iPhone SE (3rd generation) 在 Accessibility XXXL、深色模式下追加运行大点赞数布局：1 / 1 通过；合成截图人工检查确认数字保持右侧单行，等级/楼层徽章无覆盖，空间不足时仅截断左侧用户名。
- Release `iphoneos` unsigned IPA：PASS；包内 `MinimumOSVersion` 为 18.0，隐私清单可解析且不含签名或描述文件。

## 系统返回手势专项回归

2026-07-24 将旧的截图式自定义导航驱动器移除，导航返回完全交还系统：

- iOS 26 使用系统 `interactiveContentPopGestureRecognizer` 提供内容区域右划返回。
- iOS 18–25 保留系统 `interactivePopGestureRecognizer` 的左边缘右划返回。
- 首页和帖子下拉刷新不再额外挂页面级 SwiftUI `DragGesture`，改为只监听 `UIScrollView` 已有 pan recognizer 的状态；不修改它的 delegate、启用状态或失败依赖，64pt 刷新阈值和顶部限制保持不变。
- 全屏图片关闭不参与导航右划，也禁用 UIKit Zoom 的交互式拖动退出；中间右划、边缘右划和下划均留在图片页，单击图片或关闭按钮才返回来源页。

设备：iPhone 17 / iOS 26.1 (`23B86`)。

- 正常模拟器签名的完整单元测试：177 通过 / 1 条件跳过 / 0 失败，共 178 项；跳过项为 opt-in 匿名线上冒烟。
- 帖子、搜索、帖子图片区域和全屏图片手势回归：4 / 4 通过。
- 首页/帖子短下拉刷新、顶部加载圈和非顶部防误刷新：4 / 4 通过。
- 浏览历史、用户主页、搜索、贴吧和楼中楼等多层路由矩阵：10 / 10 通过，包含连续六次右划及短拖回弹。

本机只安装了 iOS 26.1 runtime，因此 iOS 18–25 没有进行实体模拟器 UI 手势注入；工程仍以 iOS 18.0 为 deployment target 完整编译，版本策略单元测试覆盖 18/25 的边缘返回与 26/27 的内容区域返回。旧系统不安装自定义手势，直接使用系统默认边缘返回。

## 图片转场竞态专项回归

本轮针对主页图片返回后立即滚动错位、放大结束闪动，以及返回后 0.5 秒内首次点击另一张图无响应，重构了图片转场源和显式生命周期：

- SwiftUI 永久持有用户看到的列表缩略图；bitmap-free 几何锚点只负责定位，UIKit Zoom 每个会话使用独立临时 `UIImageView` 代理，真实 dismiss completion 立即移除。
- session 使用 `idle → presenting → presented → dismissing → idle` 状态机；只有 UIKit 的 `present` / `dismiss` completion 才推进完成状态。
- dismiss 期间到达的新图片请求保留最后一次并在 completion 后执行；presenting/presented 阶段不积累陈旧请求。
- source provider 优先使用带 generation token 的真实点击源；结束动画重新读取当前 source 的 window frame，不复用打开时缓存的 CGRect。
- 高清图替换不再依赖 `viewDidAppear` 或额外主线程延迟，避免与系统 zoom 最后一帧争用。

设备：iPhone 17、iPhone 17 Pro、iPhone 17 Pro Max / iOS 26.1 (`23B86`)。

- 最终完整单元测试：184 通过 / 1 条件跳过 / 0 失败，共 185 项。
- 图片状态机、source token、同代位图与几何、祖先裁切、动态 source frame 和展示时序定向单元测试：12 / 12 通过。
- 图片打开、单点返回、拒绝右划退出和裁切缩略图转场：2 / 2 通过。
- 主页图片快速竞态回归覆盖连续 8 次返回后立即滚动、连续 6 次返回后首次点击另一张图，以及 LazyVStack 离屏复用：3 / 3 通过。
- 首帧竞态探针在 iPhone SE (3rd generation) 和 iPhone 17 各运行 6 轮，共 12 / 12 通过；dismiss completion 后 0–2ms 即开始真实滚动 120pt，缩略图布局层与 presentation layer 最大误差均为 0pt，临时代理残留数为 0。
- 使用合成 fixture 录制并抽查转场，不包含真实线上用户内容；关键区间请求 107 个时间采样（源视频约 18fps），未发现旧快照、留影或被点击图片单独漂移。

## 楼中楼真实用户名与单路径图片转场最终回归

帖子页楼中楼摘要不再依赖理想化的预组装 mention。真实 PB 数据即使把 `回复用户名：正文` 拆成多个 type-0 块、没有 user list 或 UID，也会恢复为名称链接；点击名称后通过 `/mo/q/search/user` 做精确匹配，只有唯一、规范化名称一致的用户才会进入主页。回复作者和被回复用户使用相同的浅灰色原生链接语义，帖子摘要与完整楼中楼均覆盖独立跳转。

图片转场不再使用三段式放大路径。最终实现由单一 app-owned `UIImageView` 代理和一条 display-link 时间线负责：外框宽高采用严格限制在起终点范围内的几何插值，归一化 crop 同步展开，最后保持一个显示帧后原子交给真实全屏图或列表缩略图。这样消除了旧实现从 2:3 裁剪图先膨胀到约 1748px、再缩回约 656px 的反向缩放。

设备：iPhone 17 / iOS 26.1 (`23B86`)。

- 正常模拟器签名的完整单元测试：201 通过 / 1 条件跳过 / 0 失败，共 202 项；跳过项为 opt-in 匿名线上冒烟。
- 最终楼中楼双链接和图片高风险集成 UI：7 / 7 通过；另行保存摘要与完整楼中楼合成截图并人工核对两处浅灰链接。
- 图片策略、来源复用、裁剪和生命周期单元测试：21 / 21 通过。
- 图片核心 UI：8 / 8 通过；图片边界 UI：5 / 5 通过，覆盖 pinch、双击复位、下载、单点退出、拒绝右/下划退出、超长图、0/1/3/4+ 媒体、失败重试和 URL 复用。
- 返回后立即上下滚动独占运行两轮，每轮 8 / 8 循环通过；首帧 race probe 6 / 6 通过，临时代理最多 1 个，代理存在时真实缩略图保持隐藏，首次真实滚动前代理已清零并完整恢复来源图。
- 真实转场录像连续 3 轮逐帧检查：打开与退出面积均单调，未发现先放大再回缩、双图、黑白空帧、残影或框内漂移。

## 小屏与无障碍矩阵

设备：iPhone SE (3rd generation) / iOS 26.1。runtime 正常可用，未启用 iPhone 13 mini fallback。

完整 fixture UI 聚合使用以下设置：

- 浅色模式
- Accessibility XXXL
- 粗体文本
- 增强对比度
- Reduce Motion

结果：**20 通过 / 4 条件跳过 / 0 失败**。四个预期跳过项是两个仅在正常动画模式运行的刷新动画测试和两个 iPad-only 测试；Reduce Motion 动画抑制测试已通过。

深色模式专项覆盖：

- 竖屏：PASS
- 横屏：PASS
- 合计：2 / 2 PASS

小屏验收覆盖搜索与帖子控制区换行、动态字体、长昵称、44pt 触控区、浅/深色对比度、Reduce Motion 和横竖屏布局；未发现文本或媒体溢出。

## iPad 矩阵

设备：iPad Pro 11-inch (M5) / iOS 26.1 (`23B86`)

- 正常动画模式完整分片：23 项通过；Reduce Motion-only 测试按条件跳过。
- Reduce Motion 专项：1 项通过。
- 去重后的完整功能聚合：**24 通过 / 0 跳过 / 0 失败**。
- 最终源码补充回归：默认字体 5 / 5 PASS；深色 Accessibility Extra Large 3 / 3 PASS。

iPad 验收覆盖横竖屏、默认/大字体、空态、错误态、长昵称、0/1/3/4+ 媒体、超宽/超长图、前后台切换、Tab Bar 空白区，以及帖子标题和摘要的完整点击区域；未发现布局溢出。

## 合成视觉验收

fixture UI 测试生成并检查了首页、搜索、帖子控制区、深色大字体和 iPad 场景。截图只包含合成夹具，不包含真实线上用户内容。截图与 `.xcresult` 仅作为本地验证证据，不提交到仓库。

## 匿名线上冒烟

- 执行时间：2026-07-13 02:46 CST
- 账号：匿名，不使用真实百度账号
- 测试：`AnonymousLiveSmokeTests/testAnonymousHomeForumSearchThreadAndMediaJourney`
- 路径：首页 → 进吧 → 搜索 → 帖子 → 媒体
- 结果：**1 通过 / 0 跳过 / 0 失败**
- 耗时：3.063 秒

此项只有在 test runner 环境显式设置 `RUN_ANONYMOUS_LIVE_SMOKE=1` 时运行；CI 不设置该变量，也不访问贴吧线上服务。

## 生成一致性与来源清单

| 检查项 | 结果 |
| --- | --- |
| XcodeGen 2.45.4 重新生成唯一 `TiebaPure.xcodeproj`，前后 hash 不变 | PASS |
| `scripts/generate-ios-protos.sh` 仅使用仓库内 `Protos/`，生成 151 个 Swift schema，前后 hash 不变 | PASS |
| `scripts/generate-asset-manifest.sh` 重新生成，前后 hash 不变 | PASS |
| `.proto` 来源文件数 | 302 |
| 与固定 TiebaLite 来源逐字节匹配的 WebP | 51 |
| 来源及再分发许可未知的 PNG | 54 |

来源固定为 TiebaLite `4.0-dev@2885b2aabbbf47aba7bf12b1cd7cbc03b1f5ec15`。未知许可 PNG 的披露不消除版权和再分发风险。

## 发布门禁

以下状态必须依据最终命令输出更新，不能以已有测试结果推断：

| 门禁 | 状态 |
| --- | --- |
| `xcodebuild analyze` | PASS |
| Debug simulator build | PASS |
| Release `iphoneos` build | PASS |
| Release app 内含且可解析 `PrivacyInfo.xcprivacy` | PASS |
| unsigned IPA 生成与结构校验 | PASS |
| IPA 内含 `PrivacyInfo.xcprivacy` | PASS |
| IPA 不含 `_CodeSignature` 与 `embedded.mobileprovision` | PASS |
| 实际暂存树无 build、DerivedData、IPA、xcresult、截图和用户数据 | PASS |
| 实际暂存树私钥、令牌、凭证扫描 | PASS |
| 最终仓库文件、LICENSE、署名与来源清单核对 | PASS |
| 当前 `main` 的 GitHub Actions | [实时状态](https://github.com/infinityf4p/TiebaPure-iOS/actions/workflows/ci.yml?query=branch%3Amain) |

### v1.1.0 发布验证

- 版本：`1.1.0 (7)`，最低系统版本 iOS 18.0。
- iPhone 17 Pro / iOS 26.1 单元测试：201 通过、1 项 opt-in 匿名线上冒烟按设计跳过、0 失败。
- XcodeGen 临时重建一致性、Release `iphoneos` unsigned 构建、IPA 解包完整性、版本元数据、arm64 架构和隐私清单检查均通过。
- 最终 Release 仍以对应 `main` 提交的 GitHub Actions 全绿为发布条件。

本地 unsigned IPA 的预期生成位置为：

```text
build/TiebaPure-unsigned.ipa
```

本次 `v1.1.0` 本地包为 `1.1.0 (7)`，SHA-256：`0629f7fc7c12833c07f9dd26c69746bc7bcd7e51fd3c98e99ae6c2ce948ec457`。包内 `MinimumOSVersion` 为 18.0，`PrivacyInfo.xcprivacy` 可解析，不含 `_CodeSignature`、`embedded.mobileprovision`、DEBUG 登录夹具或 Release 登录诊断输出。

`build/`、IPA、截图和 `.xcresult` 均被忽略，不属于公开仓库内容。IPA 故意不签名，安装前必须由使用者使用自己的证书和描述文件签名。
