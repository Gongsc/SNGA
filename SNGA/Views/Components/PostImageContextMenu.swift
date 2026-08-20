import AppKit
import SwiftUI

/// 图片的右键菜单。
///
/// 正文里的配图和点开之后的大图共用这一份：两处右键看到的项目、顺序和文案都
/// 一样，用户不必在放大之后才找得到「复制图片」。
///
/// 大图预览手里就有整张原图和它的原始数据，正文里的配图没有 —— 那里只按显示
/// 宽度解了一张缩过的位图，而复制和另存为要的是原图。手边没有就现取一次：
/// 图片刚刚才显示过，会话的缓存通常直接命中，不会真的再下一遍。
struct PostImageContextMenu: View {
    let url: URL
    /// 手边已有的整张原图。
    var image: NSImage?
    /// 手边已有的原始数据，另存为写的就是它。
    var data: Data?
    let onError: @MainActor (String) -> Void

    var body: some View {
        Button("复制图片", systemImage: "doc.on.doc") {
            copyImage()
        }
        Button("复制图片地址", systemImage: "link") {
            copyImageAddress()
        }
        Divider()
        Button("图片另存为…", systemImage: "square.and.arrow.down") {
            saveImage()
        }
        Button("在默认浏览器中打开", systemImage: "safari") {
            openInBrowser()
        }
    }

    // MARK: - 操作

    private func copyImage() {
        if let image {
            copy(image)
            return
        }
        Task {
            guard let data = await PostImageStore.shared.originalData(for: url),
                  let downloaded = NSImage(data: data) else {
                onError(Self.unavailableMessage)
                return
            }
            copy(downloaded)
        }
    }

    private func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            onError("系统剪贴板暂时无法写入图片。")
            return
        }
    }

    private func copyImageAddress() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(url.absoluteString, forType: .string) else {
            onError("系统剪贴板暂时无法写入图片地址。")
            return
        }
    }

    private func saveImage() {
        if let data {
            save(data)
            return
        }
        Task {
            guard let downloaded = await PostImageStore.shared.originalData(for: url) else {
                onError(Self.unavailableMessage)
                return
            }
            save(downloaded)
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func openInBrowser() {
        guard NSWorkspace.shared.open(url) else {
            onError("无法在默认浏览器中打开图片。")
            return
        }
    }

    private static let unavailableMessage = "暂时取不到这张图片的原图，请稍后再试。"

    private var suggestedFilename: String {
        let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return filename.isEmpty ? "NGA图片.png" : filename
    }
}
