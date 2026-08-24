# iOS 14 兼容性迁移清单

当前 TieBaPure 底座在 iOS 16.4 上运行。`project.yml` 已将产品部署目标固定为 iOS 14.0，后续每一项高版本 API 必须完成替换后才能标记首个稳定版。

| 原 API/能力 | iOS 14 实现 | 状态 |
| --- | --- | --- |
| `NavigationStack` / `NavigationSplitView` | `NavigationView` + `AppRouter` + UIKit 双栏协调器 | 待迁移 |
| `.navigationDestination` | 类型化路由和兼容导航链接 | 待迁移 |
| `.refreshable` | `UIRefreshControl` 包装器 | 待迁移 |
| `.searchable` | `UISearchController` 或自定义搜索栏 | 待迁移 |
| `PhotosPicker` | `PHPickerViewController` | 待迁移 |
| `ShareLink` | `UIActivityViewController` | 待迁移 |
| `presentationDetents` | 自定义半屏 UIKit 容器 | 待迁移 |
| `ContentUnavailableView` | 项目内兼容空状态视图 | 部分已有 |
| SwiftData | Core Data / 文件持久化兼容层 | 进行中 |
| `safeAreaInset` 等高版本修饰符 | UIKit/GeometryReader 兼容修饰符 | 待审计 |

每次迁移都需要补充一个 iOS 14 可执行的单元或 UI 测试，并在 CI 中保留 iOS 14 部署目标门禁。不能用 `if #available` 只隐藏编译错误而删除原有功能。

