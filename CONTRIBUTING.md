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

## 版本号

公开版本号 `MARKETING_VERSION` 在准备发布时递增；构建号 `CURRENT_PROJECT_VERSION` 只用于内部区分构建，不在应用界面、README 或 Release 标题中展示，并在每个会影响 App 的源码、资源、依赖或工程配置提交中递增。纯文档、测试和 CI 调整不要求递增构建号。

两个值只在 `project.yml` 中修改，随后运行 `xcodegen generate --spec project.yml` 更新工程文件。CI 会逐个检查相关提交，防止构建号遗漏或倒退。

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

日常 CI 只运行 4 项确定性 fixture 冒烟，覆盖启动、搜索、吧页分类和图片查看。新增 UI 测试不会自动加入日常 CI；提交前请在本地运行与改动相关的测试，发布前再运行完整 UI 测试集。

## 门禁失败了怎么办

CI 会验证 Xcode 工程与生成配置一致：

| 报错 | 修复 |
| --- | --- |
| `TiebaPure.xcodeproj does not match project.yml` | `xcodegen generate --spec project.yml` 后提交 |

纯文档改动（`*.md`、`docs/`）会自动跳过构建和模拟器测试。

## 来源与许可（重要）

本项目移植自 [TiebaLite](https://github.com/HuanCheng65/TiebaLite)，以 `GPL-3.0-only` 发布，并且**逐文件记录了每个二进制资源的来源**（见 [ASSET_MANIFEST.sha256](ASSET_MANIFEST.sha256) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。因此：

- **不要提交来源不明的图片、字体或其他二进制资源。** 如果你新增了资源，请在 PR 里说明它的来源和许可；维护者会在发布前核对资源清单。平台方的素材（比如贴吧表情）应当运行时拉取而不是打包 —— 打包是再分发，拉取只是显示。
- **不要移除 GPL 版权声明或免责条款**，也不要因为代码被重写成 Swift 就删掉归属信息。
- 从 TiebaLite 移植代码时，请在 PR 里注明对应的上游文件。
- `Protos/` 下的 schema 是从上游逐字节复制的，除非上游变更，否则不要手改。

## 提 PR 之前

- 本地至少跑通单元测试，以及和你改动相关的 UI 测试
- 一个 PR 只做一件事，方便审查也方便出问题时回退
- 提交信息说明**为什么**这么改，而不只是改了什么
- 如果你改了行为，相应地更新测试

同一分支连续推送时旧的 CI 会自动取消，不用等待已经过期的结果。

## CI 结构（维护者）

日常 workflow 只有一个固定检查 `ci-ok`，依次运行：

1. 构建号和 XcodeGen 一致性检查；
2. 全部离线单元测试；
3. 4 项 fixture UI 冒烟；
4. unsigned Release 构建及隐私清单检查。

UI 冒烟前会重建模拟器，避免长时间运行的设备导致 XCUITest 在 bootstrap 阶段失败。iPad、Reduce Motion、完整 UI 矩阵、protobuf 重建和静态分析不再阻塞每次提交，改为发布前本地验收。

## 发布门禁（维护者）

发布前依据**当次命令输出**逐项确认，不能以历史结果推断：

- [ ] 对应 `main` 提交的 GitHub Actions 全绿
- [ ] 完整 fixture UI 测试在 iPhone、iPad 和 Reduce Motion 场景通过
- [ ] `xcodebuild analyze` 通过
- [ ] protobuf 生成物及 `ASSET_MANIFEST.sha256` 与源文件一致
- [ ] Release `iphoneos` 构建通过
- [ ] Release app 内含且可解析 `PrivacyInfo.xcprivacy`
- [ ] `./scripts/package-unsigned-ipa.sh` 生成 IPA，结构校验通过
- [ ] IPA 内含 `PrivacyInfo.xcprivacy`，不含 `_CodeSignature`、`embedded.mobileprovision`、DEBUG 登录夹具
- [ ] 暂存树无 build、DerivedData、IPA、xcresult、截图和用户数据
- [ ] 暂存树无私钥、令牌、凭证

IPA 输出到 `build/TiebaPure-unsigned.ipa`，故意不签名，安装前需使用者用自己的证书和描述文件签名。
