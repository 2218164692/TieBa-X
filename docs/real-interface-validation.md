# 真实接口联调验收

TieBa-X 将确定性夹具测试和线上联调分开：前者验证请求构造、响应映射、错误、分页、取消和大小限制，默认在每次 CI 中执行；后者只读访问贴吧公开接口，用来确认接口路径和真实字段没有漂移。

## 覆盖范围

`TieBaXCoreTests/AnonymousLiveSmokeTests.swift` 覆盖以下链路：

- 匿名首页推荐和进吧列表；
- 吧内帖子分页、按回复时间排序；
- 全局搜索到帖子详情的跳转；
- 帖子媒体字段到受限图片下载的映射；
- 真实楼层总页数与倒序第一页策略。

测试不写入帖子、回复、点赞、收藏、签到或个人资料，不读取 Cookie，也不需要测试账号。线上内容变化、风控或网络错误都应作为联调结果记录，不能改成放宽断言来“通过”。

## 执行方式

在 macOS runner 上生成工程后，手动触发 `iOS CI` workflow，并将 `run_live_smoke` 设为 `true`。工作流会先跑完整确定性测试，再执行：

```bash
RUN_ANONYMOUS_LIVE_SMOKE=1 xcodebuild \
  -project TieBaX.xcodeproj \
  -scheme TieBaX \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled NO \
  test -only-testing:TieBaXTests/AnonymousLiveSmokeTests
```

Windows 本地没有 Xcode、iOS Simulator 和 Swift toolchain，不能把本机文本检查的通过结果当成这组联调已通过。首次发布前必须保存该 workflow 的 `.xcresult`，并在 `docs/feature-matrix.md` 中把对应模块从“需真实接口联调”更新为已验收；匿名联调失败时保持未验收状态，不推送发布标签。
