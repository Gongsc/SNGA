import Foundation
import XCTest
@testable import SNGA

/// 论坛上常有人把内容编成 Base64 再发。解码这件事最要紧的不是「解得开」，
/// 而是**不乱认** —— 一段普通英文字母本身就是合法的 Base64，照单全收的话，
/// 随手选一个词都会弹出一堆乱码。
final class Base64TextTests: XCTestCase {

    func testRoundTrip() throws {
        for text in ["hello", "中文也要能来回一趟", "带 空格\n和换行", "emoji 🐟🍜"] {
            let encoded = Base64Text.encoded(text)
            XCTAssertEqual(Base64Text.decoded(encoded), text, encoded)
        }
    }

    /// 正文里贴出来的 Base64 常常是断成几行的。
    func testWrappedBase64Decodes() {
        let wrapped = """
        5L2g5aW977yM6L+Z5piv5LiA5q615Y+v
        6IO95Lya6KKr5oqY6KGM55qE5paH5a2X
        """

        XCTAssertNotNil(Base64Text.decoded(wrapped))
    }

    /// 缺尾巴的 `=` 也要收 —— 很多人贴出来的时候就是缺的。
    func testMissingPaddingIsTolerated() {
        let padded = Base64Text.encoded("测试一下")
        let stripped = padded.replacingOccurrences(of: "=", with: "")

        XCTAssertEqual(Base64Text.decoded(stripped), "测试一下")
    }

    /// URL 安全字母表用 `-_` 代替 `+/`。
    func testURLSafeAlphabetIsTolerated() {
        let standard = Data([0xFF, 0xFE, 0x41, 0x42, 0x43]).base64EncodedString()
        XCTAssertTrue(standard.contains("+") || standard.contains("/"), standard)
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        // 这一串解出来不是合法 UTF-8，两种写法都该被拒 —— 但要拒得一致，
        // 而不是标准的拒、URL 安全的收。
        XCTAssertEqual(Base64Text.decoded(standard), Base64Text.decoded(urlSafe))
    }

    /// 这几样都不该被当成 Base64。
    func testEverydayTextIsNotMistakenForBase64() {
        for text in [
            "",
            "abc",                 // 太短，而短字符串是误判的重灾区
            "hello world",         // 有空格之外的非字母表字符……去空格后是 helloworld
            "这是一句中文",          // 根本不在字母表里
            "https://example.com", // 冒号和斜杠
            "a=bcd",               // `=` 只能在末尾
            "abcde"                // 余 1，没有哪种字节数编得出这个长度
        ] {
            XCTAssertNil(Base64Text.decoded(text), "不该认作 Base64：\(text)")
        }
    }

    /// 随手选中的一个英文词往往是合法 Base64，但解出来是乱码 —— 那两道过滤
    /// （必须是 UTF-8、不能带控制字符）就是拦它的。
    func testWordsThatHappenToBeValidBase64AreRejected() {
        for word in ["test", "password", "download", "abcdefgh"] {
            XCTAssertNil(Base64Text.decoded(word), "\(word) 解出来是乱码，不该收")
        }
    }

    func testLooksDecodableAgreesWithDecoded() {
        XCTAssertTrue(Base64Text.looksDecodable(Base64Text.encoded("能解开")))
        XCTAssertFalse(Base64Text.looksDecodable("随便一句话"))
    }
}
