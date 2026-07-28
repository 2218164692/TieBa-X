import SwiftUI

struct AboutView: View {
    private let upstreamURL = URL(string: "https://github.com/HuanCheng65/TiebaLite/tree/4.0-dev")!
    private let sourceURL = URL(string: "https://github.com/infinityf4p/TiebaPure-iOS")!
    private let authorURL = URL(string: "https://github.com/infinityf4p")!

    var body: some View {
        Form {
            Section("TiebaPure") {
                LabeledContent("版本", value: versionText)
                LabeledContent("项目作者") {
                    Link("infinityf4p", destination: authorURL)
                }
                Text("以浏览为主的非官方百度贴吧客户端；登录后支持关注用户及点赞，当前不提供发帖或回复。与百度公司及贴吧官方无隶属、授权或认可关系。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("开源与来源") {
                Link("查看 TiebaLite 来源项目", destination: upstreamURL)
                    .accessibilityHint("在浏览器打开原项目")

                Link("查看 TiebaPure-iOS 源码", destination: sourceURL)
                    .accessibilityHint("在浏览器打开本应用源码")

                LabeledContent("许可证", value: "GPL-3.0-only")
            }
        }
        .navigationTitle("关于 TiebaPure")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenInteractiveNavigationPop()
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version)（\(build)）"
    }
}
