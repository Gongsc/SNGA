import AppKit
import SwiftUI

struct AboutView: View {
    static let windowID = "about-snga"

    private static let githubURL = URL(string: "https://github.com/Gongsc/SNGA")
    private static let emailAddress = "gongsc@live.cn"
    private static let emailURL = URL(string: "mailto:\(emailAddress)")

    private let version = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.7.0"
    private let build = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "1"

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("SNGA")
                    .font(.title.bold())
                Text("Super NGA")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("版本 \(version)（\(build)）")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("面向 macOS 的原生 NGA 论坛客户端")
                .multilineTextAlignment(.center)

            Divider()

            if let emailURL = Self.emailURL {
                LabeledContent("联系邮箱") {
                    Link(Self.emailAddress, destination: emailURL)
                        .textSelection(.enabled)
                }
            }

            HStack {
                if let githubURL = Self.githubURL {
                    Link(destination: githubURL) {
                        Label("打开 GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("about-github")
                }

                if let emailURL = Self.emailURL {
                    Link(destination: emailURL) {
                        Label("发送邮件", systemImage: "envelope")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("about-email")
                }
            }

            Text("SNGA 是非官方客户端，与 NGA 官方没有从属关系。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 420)
    }
}
