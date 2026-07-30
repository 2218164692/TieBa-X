# Third-Party Notices

最后核对日期：2026-07-30。

## HuanCheng65/TiebaLite

- 项目：https://github.com/HuanCheng65/TiebaLite
- 固定来源：`4.0-dev@2885b2aabbbf47aba7bf12b1cd7cbc03b1f5ec15`
- 上游许可证：GNU General Public License v3.0
- 本仓库许可证标识：`GPL-3.0-only`

本项目显著借鉴并移植自 TiebaLite。直接或可追溯使用范围包括：

1. `Protos/` 中 302 个 protobuf schema，直接复制且逐文件一致。
2. `TiebaPure/Resources/Emoticons/` 中 51 个 WebP 表情，SHA-256/字节内容与固定上游来源一致。
3. 旧版贴吧客户端协议的端点、字段、签名方式、protobuf 请求组合和响应映射参考。
4. 广告/直播/语音等内容过滤范围、表情代码映射和部分阅读 UI 行为参考。

Swift/SwiftUI 代码包含面向 iOS 的移植、重写，以及持续进行的安全、并发和无障碍修改。GPL 版权和无担保条款不得因重写语言或平台而被移除。

## 其余表情素材

除上述 51 个 WebP 外的表情是百度的素材，**不打包进本仓库和 App**，而是在显示时从百度的 CDN 按需拉取并缓存到本机。应用只是显示它们，与显示帖子里的任何一张图片无异，不构成再分发。

早期版本曾打包过 54 个来源不明的 PNG，现已移除。[ASSET_MANIFEST.sha256](ASSET_MANIFEST.sha256) 记录每个打包资源的 SHA-256 与来源，CI 会拒绝任何来源不明的资源进入仓库。

## Apple SwiftProtobuf

- 项目：https://github.com/apple/swift-protobuf
- 当前解析版本：1.38.1
- 许可证：Apache License 2.0

SwiftProtobuf 通过 Swift Package Manager 构建，不把其仓库源码直接纳入本仓库。

## 商标与服务

“百度”“贴吧”及相关标识属于其各自权利人。本应用是非官方客户端，仅向用户请求百度公开/登录后可见的阅读数据，不代表任何官方合作或认可。

## 无担保

本项目及第三方材料按“现状”提供，不提供适销性、特定用途适用性或不侵权等担保。完整条款见 [LICENSE](LICENSE)。
