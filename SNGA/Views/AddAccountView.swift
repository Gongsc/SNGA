import SwiftUI

/// 选站点、选登录方式。
///
/// 做成中栏的一个模块而不是弹窗：站点会越来越多，NodeSeek 这样的还不止一种登录方式，
/// 一层层菜单点下去比摊开来难用。
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sngaTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ForumSite.allCases) { site in
                    siteCard(site)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.backgroundColor)
        .accessibilityIdentifier("add-account-sites")
    }

    private func siteCard(_ site: ForumSite) -> some View {
        let descriptor = site.descriptor
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SiteBadge(site: site)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.displayName)
                        .font(.headline)
                    Text(descriptor.baseURL.host() ?? "")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryForegroundColor)
                }
                Spacer()
                if existingCount(site) > 0 {
                    Text("已有 \(existingCount(site)) 个账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(descriptor.loginMethods) { method in
                Button {
                    model.session.loginSite = site
                    model.session.loginMethod = method
                    model.session.showsLogin = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: method.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(theme.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(method.title)
                            Text(method.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryForegroundColor)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("login-\(site.rawValue)-\(method.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 12))
    }

    private func existingCount(_ site: ForumSite) -> Int {
        model.session.accounts.count { $0.site == site }
    }
}

/// 站点的标记。宽度够就显示名字，不够就只留图标 —— 侧栏可以拖窄。
struct SiteBadge: View {
    let site: ForumSite
    var showsName = true

    var body: some View {
        if showsName {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    icon
                    Text(site.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
                icon
            }
        } else {
            icon
        }
    }

    private var icon: some View {
        Image(systemName: site.systemImage)
            .foregroundStyle(.secondary)
            .accessibilityLabel(site.displayName)
    }
}
