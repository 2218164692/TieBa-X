# TieBa-X

[![iOS CI](https://github.com/2218164692/TieBa-X/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/2218164692/TieBa-X/actions/workflows/ios-ci.yml)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

TieBa-X 是一个面向 iOS 14 及更高版本的非官方、无广告贴吧客户端。TiebaLite、TiebaPure-iOS、aiotieba 和 tbclient.protobuf 只用于功能、交互和协议行为参考；本项目按自己的产品契约、iOS 适配层和测试逐项重构，当前仍处于本地迁移与验收阶段。

本项目与百度公司、百度贴吧官方无隶属、授权或认可关系。“百度”“贴吧”及相关名称与标识归其各自权利人所有。发帖、回复、资料修改等能力使用非官方接口，可能触发贴吧风控；使用者需自行承担风险。

## 当前状态

- 最低部署版本：iOS 14.0
- 支持设备：iPhone、iPad
- 发布方式：源码与 GitHub Actions 构建的未签名 IPA
- 构建环境：GitHub Actions macOS Runner；本地开发不要求 Mac
- 许可证：GPL-3.0-only
- 工程源文件：`project.yml`；`TieBaX.xcodeproj` 由 XcodeGen 在 CI 中临时生成，不提交生成工程

项目当前处于本地开发阶段，尚未推送首个功能版本。已完成产品身份、iOS 14 持久化与 SwiftUI 兼容层的第一轮迁移；功能模块仍需按矩阵逐项重构、联调、来源审查和验收，完成前不会发布到 GitHub。

本地开发提交策略：每个功能模块先在本地完成实现和测试，再合并到本地 `main`；只有通过 iOS 14 模拟器测试、未签名真机构建和许可证检查后，才会由维护者手动推送到远程仓库。

## 没有 Mac 时如何构建

完成首个可发布里程碑后，本地只需要编辑代码并推送到 GitHub。Pull Request 或推送到 `main` 会触发 `iOS CI`，手动运行 `iOS Package` 可以生成测试 IPA。

创建版本时，在本地创建并推送一个语义化标签：

```bash
git tag v0.1.0
git push origin v0.1.0
```

标签工作流会在 GitHub Actions 的 macOS Runner 中：

1. 安装固定版本的 XcodeGen；
2. 根据 `project.yml` 生成 Xcode 工程；
3. 使用 Xcode 编译 Release 真机版本；
4. 在不使用证书的情况下打包未签名 IPA；
5. 生成 SHA-256 校验文件和构建信息；
6. 将文件附加到 GitHub Release。

未签名 IPA 不能直接安装，需要使用自己的证书重新签名。GitHub Actions 的临时构建文件可从对应工作流的 Artifacts 下载，正式文件从 Releases 下载。

## 参考项目

- [TiebaLite](https://github.com/zzc10086/TiebaLite)：Android 功能基准
- [TiebaPure-iOS](https://github.com/infinityf4p/TiebaPure-iOS)：iOS 行为、错误处理和媒体交互参考；不作为 TieBa-X 的发布代码底座
- [aiotieba](https://github.com/lumina37/aiotieba)：接口行为、签名和协议参考
- [tbclient.protobuf](https://github.com/n0099/tbclient.protobuf)：历史 Protobuf 定义研究资料

四个参考项目的固定提交和许可证边界记录在 `docs/reference-baseline.md`。本地迁移基线在首个发布前必须完成逐文件来源审查；未明确授权的协议资料只用于研究，不直接复制到发行物中。

功能迁移和验收状态见 [`docs/feature-matrix.md`](docs/feature-matrix.md)；每项功能先在本地完成实现、夹具/单元测试和 iOS 14 验收，再进入待推送分支。

## 本地可执行的非 Xcode检查

Windows 环境可以执行 Git、文本搜索、协议夹具检查和文档检查。Swift 编译、模拟器测试和 IPA 打包统一交给 GitHub Actions；不要在仓库中提交证书、Provisioning Profile、真实 Cookie 或测试账号。
