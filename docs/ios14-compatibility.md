# iOS 14 兼容性迁移清单

TieBa-X 的部署目标固定为 iOS 14.0。高版本 API 必须通过兼容层或独立的可用性分支，不能把 iOS 15/16/17 API 直接写进产品功能路径。

## 已完成的第一轮迁移

- SwiftData 不再是运行时依赖；草稿、浏览历史、最近贴吧和阅读位置使用 iOS 14 文件持久化。
- `NavigationStack`、`navigationDestination` 使用 TieBa-X 的 iOS 14 导航兼容层。
- `PhotosPicker` 改为 iOS 14 可用的 `PHPickerViewController` 封装。
- `ShareLink`、`refreshable`、`searchable`、`safeAreaInset`、`foregroundStyle`、`controlSize` 等高版本 API 均通过兼容封装或降级实现；系统搜索栏在 iOS 14 会变成页面内搜索框。
- 关于页的 `LabeledContent` 在 iOS 14 使用 TieBa-X 自己的横向标签/值布局。
- 下拉刷新指示器在 iOS 14 使用静态帧，iOS 15+ 才启用 `TimelineView` 动画。
- 网络端点不直接调用 iOS 16 的 `URL.appending(path:)` / `appending(queryItems:)`，统一使用 `TieBaXURLCompat` 的 `URLComponents` 回退。
- 网络请求在 iOS 15+ 使用受限流式读取；iOS 14 使用 `URLSession.dataTask` 回退，且仍执行响应大小上限。
- `Task.sleep(for:)`、状态动画和列表分隔线通过 `TieBaXTaskCompat` / SwiftUI 兼容修饰符回退到 iOS 14 API。
- `NavigationStack` 的类型化路径在 iOS 14 通过隐藏 `NavigationLink` 桥接，程序化打开帖子、贴吧和用户不会只更新状态而不跳转。
- `ViewThatFits` 的紧凑/堆叠布局在 iOS 14 使用显式 fallback，只渲染一个布局，避免两个候选布局重复出现。

| 原 API/能力 | iOS 14 实现 | 状态 |
| --- | --- | --- |
| `NavigationStack` / `NavigationSplitView` | `TieBaNavigationStack`、`TieBaNavigationPathStack`；双栏仅在 iOS 16+ 启用 | 已接入 |
| `.navigationDestination` | `tieBaNavigationDestination`；iOS 14 使用兼容导航栈 | 已接入 |
| `.refreshable` | `tieBaRefreshable`；iOS 14 保留显式刷新入口 | 已接入 |
| `.searchable` | `tieBaSearchable`；iOS 14 使用页面内搜索栏 | 已接入 |
| `PhotosPicker` | `PHPickerViewController` | 已接入 |
| `ShareLink` | `UIActivityViewController` | 已接入 |
| `presentationDetents` | iOS 16+ 使用原生半屏，iOS 14 回退普通 sheet | 已接入 |
| `ContentUnavailableView` | 项目内兼容空状态视图 | 部分已有 |
| `LabeledContent` | `TieBaFormLabeledContent` / `TieBaFormLabeledValue` | 已接入 |
| `TimelineView` | iOS 14 使用静态指示器帧 | 已接入 |
| `URL.appending(path:)` / `appending(queryItems:)` | `TieBaXURLCompat` | 已接入 |
| SwiftData | iOS 14 文件持久化；SwiftData 代码保留为显式可选分支 | 已接入 |
| `safeAreaInset` 等高版本修饰符 | `TieBaXSwiftUICompat` 统一封装并降级 | 已接入，持续审计 |

依赖 SwiftData 的历史回归测试仍保留在 `TieBaXCoreTests/` 供未来 iOS 17 分支恢复，但不会加入 iOS 14 的 `TieBaXTests` 构建目标；文件持久化和迁移测试继续在最低版本门禁中执行。

每次迁移都需要补充一个 iOS 14 可执行的单元或 UI 测试，并在 CI 中保留 iOS 14 部署目标门禁。不能用 `if #available` 只隐藏编译错误而删除原有功能。

本地静态门禁可在仓库根目录执行 `bash scripts/ios14-audit.sh`。它会检查部署目标、直接 iOS 15+ SwiftUI 调用是否误回流到功能文件，以及仍需可用性分支的 API 是否落在已审查的文件白名单内。该脚本不能替代 GitHub Actions 的 Xcode 编译、iOS 14 模拟器测试或真机构建。
