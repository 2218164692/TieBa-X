# 验证

这里只记录**不会自动过期**的东西：固定环境、测试清单、CI 结构和发布门禁。

逐次回归的结果不写在这里 —— 每次推送 CI 都会把全部测试跑一遍，结果以 [`main` 的 Actions](https://github.com/infinityf4p/TiebaPure-iOS/actions/workflows/ci.yml?query=branch%3Amain) 为准。工作流未全绿不得发布。

## 固定环境

| | 版本 |
| --- | --- |
| macOS | 26 |
| Xcode | 26.6 (`17F113`) |
| iOS 模拟器 runtime | 26.5 (`23F77`) |
| XcodeGen | 2.45.4 |
| SwiftProtobuf | 1.38.1 |
| Deployment target | iOS 18.0 |

本地与 CI 使用同一组合，均取自 `macos-26` 镜像预装内容。镜像带 Xcode 26.0.1–26.6 和 iOS 26.2/26.4/26.5 运行时，不带 26.1。运行时可以比驱动它的 Xcode 旧，不能更新，因此 26.6 配 26.5。此前钉 Xcode 26.1.1 + iOS 26.1 时，每个 job 都要先下载约 15 分钟的运行时。

模拟器 XCTest 必须按正常方式签名运行。**不要传 `CODE_SIGNING_ALLOWED=NO`** —— Keychain 回归测试会因缺少 entitlement 而照常通过，但不再验证任何东西。

## 测试清单

- 单元测试 295 项：294 项离线确定性测试，1 项 opt-in 匿名线上冒烟。
- UI 测试 84 项，即 `TiebaPureUITests.swift` 内全部测试，全部基于离线 fixture（`UITEST_USE_FIXTURES`），不访问贴吧线上服务，也不使用真实百度账号。

夹具场景：`success`、`refreshUpdate`、`emptyThenSuccess`、`empty`、`error`、`expired`、`slow`、`paginationFailure`、`longContent`、`subpostReference`、`imageGesture`。

匿名线上冒烟仅在 test runner 显式设置 `RUN_ANONYMOUS_LIVE_SMOKE=1` 时运行，CI 不设置该变量。

## CI 结构

| Job | 覆盖 |
| --- | --- |
| `verify` | 不需要模拟器的门禁：清单漂移、工具链、xcodegen、溯源清单、protobuf。约 1 分钟 |
| `unit-tests` | 294 项离线单元测试 |
| `ui-tests (reselect)` | 2 项 Tab 重选刷新 |
| `ui-tests (shard-a…d)` | 各 19–20 项 |
| `ui-tests-ipad` | 3 项 iPad-only，被跳过视为失败 |
| `ui-tests-reduce-motion` | 1 项动画抑制，被跳过视为失败 |
| `analyze-and-release` | 静态分析 + Release 构建 + 隐私清单 |

分片按**实测单测试耗时**均衡，不按数量。每个 job 有约 9.7 分钟固定开销，而 macOS 并发上限使实际并行度约 3.6，因此墙钟取决于 runner 总分钟数 —— 分片越多越慢。当前四片各约 10 分钟测试，整轮约 35 分钟 / 128 runner 分钟。

两条来之不易的约束：

- **每个 UI job 必须在构建完成后重建模拟器再跑测试。** 复用构建时那台已启动多时的设备，会让测试运行器在 bootstrap 阶段失败（`Timed out waiting for AX loaded notification` / `signal abrt while preparing to run tests`），且一个测试都不执行 —— 这种失败发生在测试启动之前，`-retry-tests-on-failure` 够不着。
- **重试的粒度是整个分片。** 配置为 `-retry-tests-on-failure -test-iterations 2 -test-repetition-relaunch-enabled YES`，某个测试失败时整片会在新进程内重跑，两次都失败才判负。因此单个抖动测试会让该分片耗时翻倍。

`ci.yml` 开头的清单漂移门禁会从 `TiebaPureUITests.swift` 提取全部 `func test*` 名称，与工作流内所有 `-only-testing` 项比对，不一致即失败。每轮必须恰好覆盖 84 项，不能把基础设施超时计作通过。

## 生成一致性与来源

CI 强制以下内容与源头一致，不一致即失败：

- `TiebaPure.xcodeproj` 与 `project.yml` 一致（XcodeGen 2.45.x）
- `TiebaPure/Core/Protobuf/Generated` 下 152 个 Swift schema 与 `Protos/` 一致（protoc 31.1 + protoc-gen-swift 1.38.1，均按固定版本现场构建）
- `ASSET_MANIFEST.sha256` 与实际资源一致，且**不含任何来源不明的资源**
- `Protos/` 下非本项目原创的 `.proto` 恰好 302 个
- 51 个 WebP 表情与固定来源逐字节匹配

来源固定为 TiebaLite `4.0-dev@2885b2aabbbf47aba7bf12b1cd7cbc03b1f5ec15`，README、THIRD_PARTY_NOTICES 和 `Protos/README.md` 三处的引用也由门禁校验。

## 发布门禁

发布前必须依据**当次命令输出**逐项确认，不能以历史结果推断：

- [ ] 对应 `main` 提交的 GitHub Actions 全绿
- [ ] Release `iphoneos` 构建通过
- [ ] Release app 内含且可解析 `PrivacyInfo.xcprivacy`
- [ ] `./scripts/package-unsigned-ipa.sh` 生成 IPA，结构校验通过
- [ ] IPA 内含 `PrivacyInfo.xcprivacy`，不含 `_CodeSignature`、`embedded.mobileprovision`、DEBUG 登录夹具
- [ ] 暂存树无 build、DerivedData、IPA、xcresult、截图和用户数据
- [ ] 暂存树无私钥、令牌、凭证
- [ ] LICENSE、署名与来源清单核对

IPA 输出到 `build/TiebaPure-unsigned.ipa`，故意不签名，安装前需使用者用自己的证书和描述文件签名。`build/`、IPA、截图和 `.xcresult` 均被忽略，不属于仓库内容。
