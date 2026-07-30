import SwiftUI

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 SNGA") {
                openWindow(id: AboutView.windowID)
            }
        }
    }
}
