# Tieba Protobuf Inputs

贴吧旧版客户端 API 用 protobuf 而非 JSON，这些 `.proto` 就是那套二进制数据的结构定义。

302 个 schema 从
[`HuanCheng65/TiebaLite`](https://github.com/HuanCheng65/TiebaLite/tree/4.0-dev/app/src/main/protos)
的 `4.0-dev@2885b2aabbbf47aba7bf12b1cd7cbc03b1f5ec15` 逐字节复制而来 —— 字段编号必须与百度服务器一致，否则什么都解不出来。`TiebaPureProfile/` 是本项目原创，不计入这 302 个，CI 统计时会排除它。

`scripts/generate-ios-protos.sh` 只读取本目录，不依赖任何外部 checkout。要生成哪些根 schema 由该脚本里的 `roots` 决定（只选阅读功能需要的，不含发帖等写入端点），脚本会递归包含它们的 import 闭包。生成需要 `python3`、`protoc` 31.1 和 `protoc-gen-swift` 1.38.1；Swift 生成器版本必须与 `Package.resolved` 里钉住的 SwiftProtobuf 版本一致，脚本会在覆盖已提交的生成产物前校验。

如果因为缺少被 import 的 schema 导致生成失败，请单独提一个改动来补充本目录中已审计的 schema 集合，不要从别处的 checkout 静默读取文件，也不要顺手加入无关的端点。
