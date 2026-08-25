# TieBa-X Protobuf 协议源

本目录保存 TieBa-X 使用的最小 Protobuf 协议定义，按接口实际需要拆分为页面、主题、回复、用户、媒体、消息、内容提交和直播信息等领域。

协议源只声明应用需要发送或读取的字段；响应中的其他字段由 Protobuf 作为未知字段保留或跳过。字段编号、wire 类型以及 `optional` / `repeated` 语义属于协议的一部分，修改时必须同步更新对应的请求编码、响应解码、领域模型映射和测试夹具。

生成的 Swift 协议代码位于 `TieBaX/Core/Protobuf/Generated/`，与本目录中的 schema 一起作为 TieBa-X 源码的一部分维护。
