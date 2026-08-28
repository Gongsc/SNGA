import Foundation

/// 把带 ANSI 转义序列的终端输出转成 HTML。
///
/// NodeSeek 的测评帖里常贴检测脚本的输出，那些输出是带颜色的：`ESC[36m` 开一段青色，
/// `ESC[0m` 收回。站点把 ESC 这个控制字符渲染成 `<span data-ansicode="27"></span>`，
/// 其余部分（`[36m`）留成普通文字，等网页版的脚本去解释。
///
/// 我们不能跑脚本（正文文档的 CSP 是 `default-src 'none'`），所以在这里解释完再交出去。
/// 不解释的话，读者看到的是一份掺着 `[36m`、`[0m` 的报告 —— 颜色没了，还多了一地噪声。
///
/// 只认最常见的那一档 SGR：粗体、暗淡、斜体、下划线、删除线，以及 8 色的前景和背景
/// （含高亮）。`38;5;N` 这类扩展色**认得出但不上色** —— 关键是把序列吃掉，
/// 宁可少一种颜色，也不要在正文里留下半截转义码。
enum ANSIText {

    /// 文本里有没有需要解释的东西。没有就别改动它。
    static func containsEscapes(_ text: String) -> Bool {
        text.contains(escape)
    }

    static func html(from text: String) -> String {
        var output = ""
        var run = ""
        var style = Style()
        var index = text.startIndex

        func flush() {
            guard !run.isEmpty else { return }
            output += style.wrap(escaped(run))
            run = ""
        }

        while index < text.endIndex {
            let character = text[index]
            guard character == escape else {
                // 别的控制字符（站点也会渲染，比如退格 0x08）留着只会变成乱码。
                // 换行和制表要留 —— 报告的排版全靠它们。
                if character.isNewline || character == "\t" || !isControl(character) {
                    run.append(character)
                }
                index = text.index(after: index)
                continue
            }
            let afterEscape = text.index(after: index)
            guard afterEscape < text.endIndex, text[afterEscape] == "[" else {
                // 不是 CSI，整个丢掉 —— 留着就是一个看不懂的字符。
                index = afterEscape
                continue
            }
            var cursor = text.index(after: afterEscape)
            var parameters = ""
            while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == ";" {
                parameters.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            let final = text[cursor]
            index = text.index(after: cursor)
            // 只有 SGR（m）改样式；别的 CSI（光标移动之类）照样吃掉，不显示。
            guard final == "m" else { continue }
            flush()
            style.apply(parameters)
        }
        flush()
        return output
    }

    // MARK: -

    private static let escape: Character = "\u{1B}"

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F }
    }

    private struct Style {
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var strike = false
        var foreground: String?
        var background: String?

        mutating func apply(_ parameters: String) {
            // `ESC[m` 等同于 `ESC[0m`。
            let codes = parameters.isEmpty
                ? [0]
                : parameters.split(separator: ";", omittingEmptySubsequences: false)
                    .map { Int($0) ?? 0 }

            var position = 0
            while position < codes.count {
                let code = codes[position]
                position += 1
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 9: strike = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 29: strike = false
                case 30...37: foreground = "fg-\(code - 30)"
                case 90...97: foreground = "fgb-\(code - 90)"
                case 39: foreground = nil
                case 40...47: background = "bg-\(code - 40)"
                case 100...107: background = "bgb-\(code - 100)"
                case 49: background = nil
                case 38, 48:
                    // 扩展色。上不了色，但它后面跟的参数必须一起吃掉 ——
                    // 漏掉的话，`5` 或 `2` 会被当成下一个 SGR 码解释成别的样式。
                    position += extendedColorLength(after: codes, from: position)
                default: break
                }
            }
        }

        /// `38;5;N` 后面还有 1 个参数，`38;2;R;G;B` 后面还有 3 个。
        private func extendedColorLength(after codes: [Int], from position: Int) -> Int {
            guard position < codes.count else { return 0 }
            switch codes[position] {
            case 5: return min(2, codes.count - position)
            case 2: return min(4, codes.count - position)
            default: return 1
            }
        }

        var classNames: [String] {
            var names: [String] = []
            if bold { names.append("ansi-b") }
            if dim { names.append("ansi-d") }
            if italic { names.append("ansi-i") }
            if underline { names.append("ansi-u") }
            if strike { names.append("ansi-s") }
            if let foreground { names.append("ansi-\(foreground)") }
            if let background { names.append("ansi-\(background)") }
            return names
        }

        func wrap(_ escapedText: String) -> String {
            let names = classNames
            guard !names.isEmpty else { return escapedText }
            return #"<span class="\#(names.joined(separator: " "))">\#(escapedText)</span>"#
        }
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
