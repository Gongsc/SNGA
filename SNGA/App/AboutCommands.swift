import SwiftUI

/// 应用菜单里的「关于 SNGA」。
///
/// 独立的关于窗删掉之后，这一项改成把主窗口切到「设置 › 关于」。菜单位置不变，
/// 只是落点从一扇新窗变成主窗口里的一页。
struct AboutCommands: Commands {
    let openAbout: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 SNGA") {
                openAbout()
                MainWindow.bringToFront()
            }
        }
    }
}
