import AppKit
import SwiftUI

/// 设置里的「关于」面板。
///
/// 原先是一扇 420pt 宽的独立窗，和设置窗一样浮在正文上。现在跟设置一起长在
/// 主窗口里：排版改成左对齐的卡片，和其他几张面板一套写法。
struct AboutView: View {
    static let displayVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.8.3"
    static let displayBuild = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "1"

    private static let githubURL = URL(string: "https://github.com/Gongsc/SNGA")
    private static let emailAddress = "gongsc@live.cn"
    private static let emailURL = URL(string: "mailto:\(emailAddress)")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SNGA")
                            .font(.title2.bold())
                        Text("Super NGA")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("版本 \(Self.displayVersion)（\(Self.displayBuild)）")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 0)
                }

                Text("面向 macOS 的原生 NGA 论坛客户端")
            }

            SettingsCard(label: "项目与联系") {
                if let emailURL = Self.emailURL {
                    SettingsFieldRow("联系邮箱") {
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
            }

            Text("SNGA 是非官方客户端，与 NGA 官方没有从属关系。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
