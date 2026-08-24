# 参考项目与许可证边界

本文件记录 TieBa-X 采用的参考版本，避免后续因为上游更新而出现不可复现的行为变化。

| 项目 | 固定提交 | 用途 | 许可证/使用边界 |
| --- | --- | --- | --- |
| [TiebaPure-iOS](https://github.com/infinityf4p/TiebaPure-iOS) | `6ab79c668ff66981963ce4cc19932d43780006a5` | iOS 交互、网络错误处理和媒体行为对照 | GPL-3.0-only；不把其页面或测试原样作为 TieBa-X 产品代码 |
| [TiebaLite](https://github.com/zzc10086/TiebaLite/tree/4.0-dev) | `268f388c7824ae2c8f6ed549827a943ec8a7f352` | 功能清单、页面行为、接口调用关系 | GPL-3.0；只移植与 iOS 兼容的功能 |
| [aiotieba](https://github.com/lumina37/aiotieba) | `bae68256fd250d5178e1447899ffa155c77eda38` | API、参数签名、加密和错误行为交叉验证 | Unlicense；保留来源说明 |
| [tbclient.protobuf](https://github.com/n0099/tbclient.protobuf) | `31383157abcfbaefcdc8dfffac1e296da2ca0f0e` | 历史协议字段研究 | 根目录没有明确许可证；不直接复制或重新发布其文件 |

## 复用原则

1. 参考项目只提供行为假设和兼容性对照；TieBa-X 先写产品需求、接口契约和测试，再逐模块重构实现。当前本地迁移基线不等于首个可发布版本。
2. Swift 源码、资源和生成代码只有在许可证兼容且保留声明时才可复制；默认不复制页面、测试和品牌资源。首个发布前必须完成逐文件来源审查并替换不符合本项目边界的内容。
3. 没有许可证的仓库只作为观察和研究资料；正式代码使用自行编写的 Swift 实现或已授权的 GPL 兼容定义。
4. 任何新加入的第三方代码必须在 `LICENSES/` 和本文件登记来源、版本、许可证和修改内容。
5. 发行物不包含百度官方客户端反编译代码、官方图标或官方品牌资源。
