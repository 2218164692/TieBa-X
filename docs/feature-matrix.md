# TieBa-X 功能迁移矩阵

本矩阵是本地开发的验收清单。参考项目只用于确认行为和协议边界；每一项都必须先有 TieBa-X 自己的接口契约、实现和测试，完成后才进入可发布分支。

| 模块 | TieBa-X 实现位置 | 当前阶段 | iOS 14 验收重点 |
| --- | --- | --- | --- |
| 首页推荐 / 分页 | `Features/Home`、`Core/Network/TiebaAPI.swift` | 已有首版，分页/过滤契约已覆盖，需真实接口联调 | 空页、分页、屏蔽后继续加载 |
| 进吧 / 关注贴吧 | `Features/ForumHub`、`Features/ForumList` | 已有首版，需联调 | 自定义搜索栏、导航回退、最近贴吧持久化 |
| 吧内帖子 / 分类排序 | `Features/Forum` | 已有首版，需联调 | 最新/精华、关键词屏蔽、无账号浏览 |
| 帖子详情 / 楼中楼 | `Features/Thread` | 已有首版，ID/分页/Protobuf 契约已覆盖，需媒体和真实分页验收 | 阅读位置、回复分页、横竖屏 |
| 全局 / 吧内搜索 | `Features/Search`、`Core/Network/TiebaSearchAPI.swift` | 请求构造、编码、响应映射和失败路径已覆盖，需真实接口联调 | iOS 14 页面内搜索、历史、用户/贴吧/帖子跳转 |
| 登录与会话失效 | `Features/Login`、`Core/Auth` | 已有首版，需真实账号风险评估 | Cookie 不落盘、失效退出、WebView 回调 |
| 关注、粉丝、点赞、收藏 | `Core/Network/TiebaSocialAPI.swift`、`Features/Profile` | 已有首版，需写操作回归 | 重复点击、失败回滚、会话隔离 |
| 签到 | `Core/Network/TiebaForumSignAPI.swift`、`Core/State/ForumSignCoordinator.swift` | 已有首版，需联调 | 手动/自动签到、失败不重复提交 |
| 发帖 / 回帖 / 图片 | `Features/Compose`、`Core/Network/TiebaContentSubmissionAPI.swift` | 已有首版，iOS 14 图片选择已接入 | PHPicker、草稿、图片上限、结果待确认 |
| 消息 | `Features/Messages`、`Core/Network/TiebaMessageAPI.swift` | 已有首版，需接口联调 | 分页、未登录状态、重试 |
| 资料编辑 | `Features/Profile/UserProfileView`、`Core/Network/TiebaUserProfileAPI.swift` | 已有首版，需风险与回滚验收 | 输入校验、写入失败不覆盖本地状态 |
| 图片 / 视频 / 语音 | `Features/Media`、`Features/Voice` | MIME、大小上限、取消和请求头契约已覆盖，需设备验收 | 缓存上限、蜂窝网络提示、分享/保存 |
| 屏蔽、历史、阅读位置 | `Domain/Models`、`Features/Settings`、`Features/Profile` | iOS 14 文件持久化已接入 | 冷启动恢复、迁移、损坏文件恢复 |
| 备份 / 恢复 | `Features/Settings/SavedThreadsView.swift` | 已有首版，需跨版本验收 | `tiebaxbackup`、媒体缺失、合并/替换 |
| 深链接 / Safari 分享 | `App/ExternalRoute.swift`、`TieBaXOpenIn` | TieBa-X scheme 已接入 | `tiebax://`、旧 `tiebapure://` 兼容、非法 URL 拒绝 |
| 主题、字体、iPad 双栏 | `Core/UI`、`Domain/Models/ReadingPreferences.swift` | 已有首版，需设备矩阵验收 | iOS 14 动态字体、深色模式、窄宽度布局 |
| 来源与许可证 | `docs/source-audit.md`、`scripts/source-audit.sh` | 自动门禁已接入，逐文件人工审查进行中 | 不发布未核对来源、签名材料或未声明依赖 |

## 完成定义

一个模块只有同时满足以下条件，才可以从“已有首版”改为“已验收”：

1. 业务实现不依赖参考项目的页面、测试或品牌资源。
2. 至少有一个 TieBa-X 单元测试或夹具场景覆盖成功、空数据和失败路径。
3. iOS 14 设备/模拟器能够完成主流程；高版本 API 只出现在兼容层或可用性分支。
4. 真实账号写操作经过明确的风险提示，网络结果不确定时不会自动重试造成重复操作。
5. 本地 CI、未签名 Release 构建和许可证检查全部通过后，才允许合并到待推送分支。
