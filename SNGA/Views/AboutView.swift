import AppKit
import SwiftUI

/// 设置里的「关于」面板。
///
/// 原先是一扇 420pt 宽的独立窗，和设置窗一样浮在正文上。现在跟设置一起长在
/// 主窗口里：排版改成左对齐的卡片，和其他几张面板一套写法。
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme

    @State private var isCheckingForUpdate = false
    @State private var updateStatus: UpdateStatus?
    @State private var updateTask: Task<Void, Never>?

    /// 查更新这一下的结果。失败不当成「有更新」，也不当成「已是最新」——
    /// 那两句都是断言，而查不到的时候我们什么也不知道。
    private enum UpdateStatus: Equatable {
        case upToDate
        case available(AppRelease)
        case failed(String)

        var message: String {
            switch self {
            case .upToDate:
                "当前已是最新版本"
            case let .available(release):
                "发现新版本 \(release.version)，可在 GitHub 下载"
            case let .failed(reason):
                "检查更新失败\n\(reason)"
            }
        }

        var systemImage: String {
            switch self {
            case .upToDate: "checkmark.circle.fill"
            case .available: "arrow.down.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        /// 「有新版本」不是错误也不是成功，所以既不红也不绿 —— 用主题强调色。
        /// 成功绿、失败红是语义色，按惯例不跟主题走。
        func tint(theme: ResolvedAppTheme) -> Color {
            switch self {
            case .upToDate: .green
            case .available: theme.accentColor
            case .failed: .red
            }
        }
    }

    static let displayVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.9.0"
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

                updateRow
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
        .onDisappear {
            // 离开面板就别再改一个已经看不见的状态了。
            updateTask?.cancel()
            updateTask = nil
        }
    }

    /// 「检查更新」那一行，以及查完之后的那句话。
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    checkForUpdate()
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isCheckingForUpdate)
                .accessibilityIdentifier("about-check-update")

                if isCheckingForUpdate {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在检查更新")
                }
            }

            if let updateStatus {
                Label(updateStatus.message, systemImage: updateStatus.systemImage)
                    .font(.caption)
                    .foregroundStyle(updateStatus.tint(theme: theme))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("about-update-status")
            }
        }
    }

    private func checkForUpdate() {
        updateTask?.cancel()
        isCheckingForUpdate = true
        updateStatus = nil
        let checker = model.updateChecker
        updateTask = Task {
            do {
                let result = try await checker.checkForUpdate(
                    currentVersion: Self.displayVersion
                )
                try Task.checkCancellation()
                switch result {
                case .upToDate:
                    updateStatus = .upToDate
                case let .updateAvailable(release):
                    updateStatus = .available(release)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                updateStatus = .failed(error.localizedDescription)
            }
            isCheckingForUpdate = false
            updateTask = nil
        }
    }
}
