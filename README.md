# TiebaPure-iOS

[![iOS CI](https://github.com/infinityf4p/TiebaPure-iOS/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/infinityf4p/TiebaPure-iOS/actions/workflows/ci.yml?query=branch%3Amain)

> 移植并借鉴自 [HuanCheng65/TiebaLite](https://github.com/HuanCheng65/TiebaLite/tree/4.0-dev)，基线固定为 `4.0-dev@2885b2aabbbf47aba7bf12b1cd7cbc03b1f5ec15`。感谢原作者与所有贡献者。

用 SwiftUI 写的第三方百度贴吧客户端，专注于看帖。

不登录就能刷首页推荐、进吧、搜帖、看楼中楼和图片视频；用手机号验证码登录后可以看消息、关注用户、点赞。不提供发帖和回复。

## 功能

- 首页推荐，进吧，吧内「最新 / 精华」分类与排序，吧内搜索
- 帖子详情、楼中楼、图片缩放保存、视频播放
- 关键词 / 用户 / 吧屏蔽，浏览历史，帖子收藏，阅读位置自动恢复
- 消息（回复我的 / @ 我的）、关注的用户与贴吧
- iPad 双栏布局，深浅色切换，支持「减弱动态效果」
- 深链接 `tiebapure://thread/...`、`tiebapure://forum/...`

登录凭证只写 Keychain，其余数据一律留在本机，不上传。详见 [PRIVACY.md](PRIVACY.md)。

## 构建

需要 iOS 18.0+、Xcode 26.6、iOS 26.5 模拟器、XcodeGen 2.45+。工程文件由 `project.yml` 生成，不要手改。

```bash
xcodegen generate --spec project.yml
```

```bash
xcodebuild -project TiebaPure.xcodeproj -scheme TiebaPure \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```

测试全部基于离线 fixture，不碰线上服务。跑法和验证结果见 [docs/verification.md](docs/verification.md)。

## 许可证

[GPL-3.0-only](LICENSE)，修改日期 **2026-07-27**，不提供任何明示或暗示的担保。

Swift/SwiftUI 代码是本项目的原创实现，但 `Protos/` 下的 302 个 `.proto` 和 51 个 WebP 表情直接复制自 TiebaLite，协议字段和内容过滤规则也参考了它。另有 54 个 PNG 表情来源与许可未知，不在 GPL 授权范围内。逐文件说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [ASSET_MANIFEST.sha256](ASSET_MANIFEST.sha256)。

## 免责声明

本项目与百度公司、百度贴吧官方及 TiebaLite 原作者均无隶属、授权或认可关系，仅供学习交流使用。
