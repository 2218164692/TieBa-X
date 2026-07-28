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

CI 用的是同一组合，均取自 `macos-26` 运行器镜像预装内容。Xcode 版本务必对上：`.xcodeproj` 是生成物，不同版本的 XcodeGen 会生成出不同的文件，导致门禁报出与你改动无关的 diff。

运行时可以比驱动它的 Xcode 旧，但不能更新，所以是 26.6 配 26.5。

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

当前有单元测试 295 项（294 项离线 + 1 项 opt-in 匿名线上冒烟）和 UI 测试 84 项。UI 测试全部基于离线 fixture（`UITEST_USE_FIXTURES`），不访问贴吧线上服务，也不需要真实百度账号；夹具场景为 `success`、`refreshUpdate`、`emptyThenSuccess`、`empty`、`error`、`expired`、`slow`、`paginationFailure`、`longContent`、`subpostReference`、`imageGesture`。

匿名线上冒烟仅在显式设置 `RUN_ANONYMOUS_LIVE_SMOKE=1` 时运行，CI 不设置该变量。

## 加 UI 测试

直接加就行，**不用碰 CI 配置**。`scripts/plan-ui-shards.py` 每轮从测试源码重新计算分片，新测试自动落到某一片。

测试通过自己的源码决定归属：带 iPad 守卫（`userInterfaceIdiom == .pad`）的进 iPad job，带 `isReduceMotionEnabled` 守卫的进 Reduce Motion job，名字以 `testHomeTabReselect` 开头的进 reselect job，其余按实测耗时均衡到四个 iPhone 分片。

分片按耗时而非数量均衡，耗时数据在 `scripts/ui-test-durations.tsv`。新测试不在表里时按平均值计 —— 不影响正确性，只是均衡度略降；想刷新这份数据，从一轮全绿 CI 的日志里提取 `Test Case ... passed (N seconds)` 即可。

## 门禁失败了怎么办

CI 里有几道检查会验证「生成物和源头一致」。失败时错误信息里会写明该跑哪条命令，这里是完整清单：

| 报错 | 修复 |
| --- | --- |
| `TiebaPure.xcodeproj does not match project.yml` | `xcodegen generate --spec project.yml` 后提交 |
| `ASSET_MANIFEST.sha256 is out of date` | `./scripts/generate-asset-manifest.sh` 后提交 |
| `Generated protobuf sources do not match Protos/` | `./scripts/generate-ios-protos.sh` 后提交（需要 protoc 31.1 和 protoc-gen-swift 1.38.1） |

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

## CI 结构（维护者）

| Job | 覆盖 |
| --- | --- |
| `verify` | 不需要模拟器的门禁：工具链、xcodegen、溯源清单、protobuf。约 1 分钟 |
| `unit-tests` | 294 项离线单元测试 |
| `ui-tests (reselect)` | 2 项 Tab 重选刷新 |
| `ui-tests (shard-a…d)` | 各 19–20 项 |
| `ui-tests-ipad` | 3 项 iPad-only，被跳过视为失败 |
| `ui-tests-reduce-motion` | 1 项动画抑制，被跳过视为失败 |
| `analyze-and-release` | 静态分析 + Release 构建 + 隐私清单 |

分片按实测耗时均衡，不按数量。每个 job 有约 9.7 分钟固定开销，而 macOS 并发上限使实际并行度约 3.6，因此墙钟取决于 runner 总分钟数 —— **分片越多越慢**。

两条来之不易的约束，改工作流时别踩：

- **每个 UI job 必须在构建完成后重建模拟器再跑测试。** 复用构建时那台已启动多时的设备，会让测试运行器在 bootstrap 阶段失败（`Timed out waiting for AX loaded notification`），且一个测试都不执行 —— 这种失败发生在测试启动之前，`-retry-tests-on-failure` 够不着。
- **重试的粒度是整个分片**，不是单个测试。所以一个抖动测试会让该分片耗时翻倍。

## 发布门禁（维护者）

发布前依据**当次命令输出**逐项确认，不能以历史结果推断：

- [ ] 对应 `main` 提交的 GitHub Actions 全绿
- [ ] Release `iphoneos` 构建通过
- [ ] Release app 内含且可解析 `PrivacyInfo.xcprivacy`
- [ ] `./scripts/package-unsigned-ipa.sh` 生成 IPA，结构校验通过
- [ ] IPA 内含 `PrivacyInfo.xcprivacy`，不含 `_CodeSignature`、`embedded.mobileprovision`、DEBUG 登录夹具
- [ ] 暂存树无 build、DerivedData、IPA、xcresult、截图和用户数据
- [ ] 暂存树无私钥、令牌、凭证

IPA 输出到 `build/TiebaPure-unsigned.ipa`，故意不签名，安装前需使用者用自己的证书和描述文件签名。
