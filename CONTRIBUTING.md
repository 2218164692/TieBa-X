# 贡献指南

欢迎提 issue 和 PR。这个项目有几条不太常见的约定，多半和它的来源与许可有关 —— 先读这一页能省下你一轮 CI 的等待。

## 环境

| | 版本 |
| --- | --- |
| macOS | 26 |
| Xcode | 26.6 |
| iOS 模拟器 runtime | 26.5 |
| XcodeGen | 2.45.x |
| Deployment target | iOS 18.0 |

CI 用的是同一组合。Xcode 版本务必对上：`.xcodeproj` 是生成物，不同版本的 XcodeGen 会生成出不同的文件，导致门禁报出与你改动无关的 diff。

## 构建与测试

工程文件由 `project.yml` 生成，**不要手改 `TiebaPure.xcodeproj`**，改了也会被下一次生成覆盖：

```bash
xcodegen generate --spec project.yml
```

```bash
xcodebuild -project TiebaPure.xcodeproj -scheme TiebaPure \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```

单元测试：

```bash
xcodebuild -project TiebaPure.xcodeproj -scheme TiebaPure \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath /tmp/TiebaPureDerivedData \
  test -only-testing:TiebaPureTests
```

跑模拟器测试时**不要**传 `CODE_SIGNING_ALLOWED=NO`。Keychain 相关的回归测试依赖 entitlement，去掉签名它们会照常通过但不再验证任何东西。

测试全部基于离线 fixture（`UITEST_USE_FIXTURES`），不访问贴吧线上服务，也不需要真实百度账号。完整的设备矩阵和分片说明见 [docs/verification.md](docs/verification.md)。

## 加 UI 测试要同时改 ci.yml

这是目前最容易踩的一条。UI 测试分片是写死在 [`.github/workflows/ci.yml`](.github/workflows/ci.yml) 的 matrix 里的，新增测试必须同时把它加进某个分片：

```yaml
-only-testing:TiebaPureUITests/TiebaPureUITests/testYourNewTest
```

不加的话 `verify` 会在一分钟内失败，并打印出缺了哪一项。这道门禁的作用是保证没有测试被静默漏跑。

分片是按**实测耗时**均衡的（每片约 10 分钟），不是按数量。加测试时挑当前最短的那片就行，不必精确。

> 这条要求不太合理，我们知道。让 CI 自动分片的改造在计划中，届时这一节会删掉。

## 门禁失败了怎么办

CI 里有几道检查会验证「生成物和源头一致」。失败时错误信息里会写明该跑哪条命令，这里是完整清单：

| 报错 | 修复 |
| --- | --- |
| `TiebaPure.xcodeproj does not match project.yml` | `xcodegen generate --spec project.yml` 后提交 |
| `ASSET_MANIFEST.sha256 is out of date` | `./scripts/generate-asset-manifest.sh` 后提交 |
| `Generated protobuf sources do not match Protos/` | `./scripts/generate-ios-protos.sh` 后提交（需要 protoc 31.1 和 protoc-gen-swift 1.38.1） |
| 白名单缺失/多余 | 按上一节增删 `ci.yml` 里的 `-only-testing` |

纯文档改动（`*.md`、`docs/`）会自动跳过模拟器相关的 job，几分钟就能出结果。

## 来源与许可（重要）

本项目移植自 [TiebaLite](https://github.com/HuanCheng65/TiebaLite)，以 `GPL-3.0-only` 发布，并且**逐文件记录了每个二进制资源的来源**（见 [ASSET_MANIFEST.sha256](ASSET_MANIFEST.sha256) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。因此：

- **不要提交来源不明的图片、字体或其他二进制资源。** 如果你新增了资源，请在 PR 里说明它的来源和许可，CI 会拒绝来源不明的资源。平台方的素材（比如贴吧表情）应当运行时拉取而不是打包 —— 打包是再分发，拉取只是显示。
- **不要移除 GPL 版权声明或免责条款**，也不要因为代码被重写成 Swift 就删掉归属信息。
- 从 TiebaLite 移植代码时，请在 PR 里注明对应的上游文件。
- `Protos/` 下的 schema 是从上游逐字节复制的，除非上游变更，否则不要手改。

## 提 PR 之前

- 本地至少跑通单元测试，以及和你改动相关的 UI 测试
- 一个 PR 只做一件事，方便审查也方便出问题时回退
- 提交信息说明**为什么**这么改，而不只是改了什么
- 如果你改了行为，相应地更新测试

CI 一轮约 35 分钟。同一分支连续推送时旧的会自动取消，所以发现问题直接再推一版即可，不用等前一轮跑完。
