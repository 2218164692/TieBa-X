# TieBa-X 来源与许可证审查

这份清单是首次发布前的来源门禁，不把“能编译”当成“来源已经清理”。参考仓库只用于行为、协议和字段研究；TieBa-X 不把参考项目作为运行时依赖，也不会把未完成来源核对的文件标记为可发布。

## 当前分类

| 范围 | 当前处理 | 发布前要求 |
| --- | --- | --- |
| `TiebaPure/App`、`Core`、`Domain`、`Features` | TieBa-X 本地迁移基线；新增兼容层、请求策略和持久化代码由本项目维护 | 逐文件检查是否仍存在参考项目页面、测试或品牌资源的原样内容；必要时重写并保留变更记录 |
| `TiebaPure/Core/Protobuf/Generated` | 从仓库内 `Protos/` 生成的 SwiftProtobuf 类型；字段名和 wire package 需要保持协议兼容 | 逐个 `.proto` 与生成文件核对；确认没有从无许可证仓库直接复制的文件；发布时保留生成器和版本记录 |
| `Protos/` | TieBa-X 的协议兼容定义 | 明确每个字段的来源、修改和许可证；没有许可证的资料只能用于研究，不能直接重新发布 |
| `TiebaPure/Core/UI/TieBaX*`、`TieBaXTests`、`TieBaXUITests` | TieBa-X 新增的产品身份、iOS 14 兼容层、契约测试和门禁测试 | 保持测试与实现的产品命名和行为契约，不复制参考项目测试 |
| SwiftProtobuf 1.38.1 | 外部包依赖，未 vendoring | 随应用分发 Apache-2.0 文本，版本必须与 `project.yml` 一致 |
| TiebaLite、TiebaPure-iOS、aiotieba、tbclient.protobuf | 文档中的固定版本参考，不是运行时依赖 | 仅保留固定提交、用途和许可证边界；禁止把没有授权的源文件加入发行物 |

## 自动门禁

在本地或 GitHub Actions 执行：

```bash
bash scripts/source-audit.sh
```

脚本会检查 GPL 和 Apache-2.0 文本、SwiftProtobuf 固定版本、参考边界、未审查的 vendored framework、签名/账号文件、生成工程和 protobuf 生成标记。它不能代替人工逐文件审查，所以首个可发布提交仍必须由维护者完成来源确认。

## 当前结论

本地基线已具备自动门禁，但来源审查仍是“进行中”，不是“全部通过”。在人工审查完成、iOS 14 真机/模拟器测试和未签名 Release 构建通过前，不创建发布标签，也不推送 GitHub。
