# GitHub Actions 构建说明

TieBa-X 不要求本地 Mac。Swift 编译和 IPA 打包在 GitHub Actions 的 macOS Runner 中完成。

## 工作流

- `ios-ci.yml`：Pull Request、`main` 推送和手动运行；生成工程、解析 SwiftPM、执行测试并验证 iOS 14 部署目标。
- `ios-package.yml`：手动运行生成测试 IPA；推送 `vX.Y.Z` 标签时生成正式未签名 IPA 并创建 GitHub Release。

## 版本发布

```bash
git checkout main
git pull
git tag v0.1.0
git push origin v0.1.0
```

Release 附件包括：

- `TieBa-X-<version>-unsigned.ipa`
- `TieBa-X-<version>-unsigned.ipa.sha256`
- `TieBa-X-<version>-build-info.json`

IPA 没有 Apple 签名，必须用使用者自己的开发者证书重新签名。构建日志和 `.xcresult` 只用于诊断，不包含账号 Cookie。

