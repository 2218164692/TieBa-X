# TieBa-X

[![iOS CI](https://github.com/2218164692/TieBa-X/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/2218164692/TieBa-X/actions/workflows/ios-ci.yml)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)

TieBa-X 是一个面向 iOS 14 及更高版本的非官方、无广告贴吧客户端。项目以 TiebaPure-iOS 的网络和 UI 实现为演进底座，按 TiebaLite 的功能清单逐步补齐功能，并使用公开的贴吧协议资料进行交叉验证。

本项目与百度公司、百度贴吧官方无隶属、授权或认可关系。“百度”“贴吧”及相关名称与标识归其各自权利人所有。发帖、回复、资料修改等能力使用非官方接口，可能触发贴吧风控；使用者需自行承担风险。

## 当前状态

- 最低部署版本：iOS 14.0
- 支持设备：iPhone、iPad
- 发布方式：源码与 GitHub Actions 构建的未签名 IPA
- 构建环境：GitHub Actions macOS Runner；本地开发不要求 Mac
- 许可证：GPL-3.0-only

项目当前处于基础迁移阶段。TiebaPure 的现有功能会先保持可追溯，再逐步改名、回移 iOS 14 API，并补齐 TiebaLite 中的功能。

## 没有 Mac 时如何构建

本地只需要编辑代码并推送到 GitHub。Pull Request 或推送到 `main` 会触发 `iOS CI`，手动运行 `iOS Package` 可以生成测试 IPA。

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
- [TiebaPure-iOS](https://github.com/infinityf4p/TiebaPure-iOS)：iOS 底座和现有测试
- [aiotieba](https://github.com/lumina37/aiotieba)：接口行为、签名和协议参考
- [tbclient.protobuf](https://github.com/n0099/tbclient.protobuf)：历史 Protobuf 定义研究资料

四个参考项目的固定提交和许可证边界记录在 `docs/reference-baseline.md`。未明确授权的协议资料只用于研究，不直接复制到发行物中。

## 本地可执行的非 Xcode检查

Windows 环境可以执行 Git、文本搜索、协议夹具检查和文档检查。Swift 编译、模拟器测试和 IPA 打包统一交给 GitHub Actions；不要在仓库中提交证书、Provisioning Profile、真实 Cookie 或测试账号。
