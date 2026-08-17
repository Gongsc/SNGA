import SwiftUI

/// 匿名标记。NGA 对匿名话题和匿名楼层只给出一个按人固定的化名，不公开真实用户，
/// 界面用这个图标提示读者：这里的名字点不进用户资料，也不是同一个人在别处的名字。
struct AnonymousBadge: View {
    /// 图标相对当前文字的大小。话题标题比正文大，用 `.medium` 更协调。
    var scale: Image.Scale = .small

    var body: some View {
        Image(systemName: "theatermasks.fill")
            .imageScale(scale)
            .foregroundStyle(.secondary)
            .help(Self.title)
            .accessibilityLabel(Self.title)
    }

    /// 与网页版 `commonui.PB` 里那条匿名标记的说明一致。
    static let title = "匿名，不显示发帖人信息"
}
