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
            let body = ANSIText.markingWideCharacters(escapedText)
            let names = classNames
            guard !names.isEmpty else { return body }
            return #"<span class="\#(names.joined(separator: " "))">\#(body)</span>"#
        }
    }

    /// 把连续的中日韩字符包起来，好让 CSS 把它们补足成两个拉丁字位宽。
    ///
    /// 报告是按终端排版的：一个汉字算两列。而网页里等宽字体的拉丁字宽是 0.6021em，
    /// 汉字是 1em —— 比值 1.66 而不是 2，所以每出现一个汉字，后面的列就左移 0.2 个字位，
    /// 一行汉字标签多几个字，整张表就斜了。
    ///
    /// 正规的办法是 `size-adjust`，但**这个 WebKit 不支持**（`CSS.supports` 实测为 false）。
    /// 退而求其次：给这些字加 `letter-spacing`，差多少补多少。数值见
    /// `PostDocument.terminalStyleSheet`，两者必须一起改。
    ///
    /// 只包宽字符：拉丁部分本来就是对的，包进去反而会被补出多余的间距。
    static func markingWideCharacters(_ escapedText: String) -> String {
        var output = ""
        var run = ""
        var runIsWide = false

        func flush() {
            guard !run.isEmpty else { return }
            output += runIsWide ? #"<span class="ns-w">\#(run)</span>"# : run
            run = ""
        }

        for character in escapedText {
            let wide = isWide(character)
            if wide != runIsWide {
                flush()
                runIsWide = wide
            }
            run.append(character)
        }
        flush()
        return output
    }

    /// 终端里占两列的字符。
    ///
    /// 只收「东亚宽」和「全角」这两类 —— 它们在等宽字体里稳定是 1em。表情符号没有收：
    /// 它的渲染宽度各家不一，补一个固定值只会补歪。
    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x1100...0x115F,            // 谚文字母
             0x2E80...0x303E,            // 部首、康熙部首、中日韩符号与标点
             0x3041...0x33FF,            // 假名、注音、兼容字符
             0x3400...0x4DBF,            // 扩展 A
             0x4E00...0x9FFF,            // 基本汉字
             0xA000...0xA4CF,            // 彝文
             0xAC00...0xD7A3,            // 谚文音节
             0xF900...0xFAFF,            // 兼容汉字
             0xFE10...0xFE19,            // 竖排标点
             0xFE30...0xFE6F,            // 兼容形式
             0xFF00...0xFF60,            // 全角形式
             0xFFE0...0xFFE6,            // 全角符号
             0x20000...0x2FFFD,          // 扩展 B 及以后
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
