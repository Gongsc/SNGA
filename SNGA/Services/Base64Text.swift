import Foundation

/// 正文里的 Base64。
///
/// 论坛上常有人把内容编成 Base64 再发 —— 挡爬虫、藏剧透、或者只是不想被搜到。
/// 读的人要能解开，写的人要能编上，两件事共用这一份。
///
/// **解码要宁可不认，也不能乱认。** 一段普通的英文字母本身就是合法的 Base64
/// （`test` 解出来是三个字节），照单全收的话，随便选一个词都会弹出一堆乱码。
/// 所以解出来之后还要过两道：必须是合法的 UTF-8，而且不能带控制字符。
/// 这两道挡不住全部误判，但挡得住绝大多数 —— 随机字节几乎不可能同时满足。
enum Base64Text {
    /// 把一段文字编成 Base64。
    static func encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// 把一段 Base64 解回文字。认不出就返回 nil。
    ///
    /// 宽进：正文里的 Base64 常常是断成几行贴出来的，也常常缺尾巴的 `=`，
    /// 还有用 URL 安全字母表（`-_` 代替 `+/`）的。这几种都收。
    static func decoded(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        // 四个字符才编得出一个字节。比这短的一律不是 —— 而短字符串恰恰是
        // 误判的重灾区（一个「abc」谁都能选中）。
        guard compact.count >= 4 else { return nil }
        // URL 安全字母表换回标准的，再补齐长度。
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard normalized.allSatisfy(isBase64Character) else { return nil }
        // `=` 只能在末尾。夹在中间说明这压根不是一段 Base64。
        if let firstPadding = normalized.firstIndex(of: "="),
           normalized[firstPadding...].contains(where: { $0 != "=" }) {
            return nil
        }
        let remainder = normalized.count % 4
        if remainder > 0 {
            // 余 1 是不可能的长度：没有哪种字节数能编出这个余数。
            guard remainder != 1 else { return nil }
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized),
              !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              // 解出来带控制字符，说明解错了 —— 那是把随便一段字母当 Base64
              // 硬解的典型结果。换行、回车、制表符是正文里真会有的，放行。
              decoded.unicodeScalars.allSatisfy(isAcceptableScalar) else {
            return nil
        }
        return decoded
    }

    /// 这段文字看起来值不值得给一个「解码」的入口。
    ///
    /// 就是「解得开吗」。单独给个名字是因为调用方问的是这件事，而不是要那个结果 ——
    /// 菜单要在画出来之前就知道该不该画。
    static func looksDecodable(_ text: String) -> Bool {
        decoded(text) != nil
    }

    private static func isBase64Character(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "+" || character == "/" || character == "="
    }

    private static func isAcceptableScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
        // C0 和 DEL、以及 C1 那一段。正文里不会有这些。
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if (0x80...0x9F).contains(scalar.value) { return false }
        return true
    }
}
