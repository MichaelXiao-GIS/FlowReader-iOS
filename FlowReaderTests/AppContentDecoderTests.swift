import XCTest
import CryptoKit
@testable import FlowReader

final class AppContentDecoderTests: XCTestCase {
    func testBundledDictionaryRestoresSyntheticTextUsingExactUpstreamPairs() throws {
        XCTAssertEqual(try AppContentDecoder.decode("雀曙，咸芹。"), "你好，世界。")
        XCTAssertEqual(try AppContentDecoder.decode("款裔炯绳瓜因。"), "这是测试正文。")
        XCTAssertEqual(try AppContentDecoder.decode("抡瓜啥束墅构克珍。"), "真正的故事开始了。")
        XCTAssertEqual(AppContentDecoder.formatVersion, 4)
    }

    func testOnePassDoesNotCascadeThroughOverlappingDictionaryKeys() throws {
        // These are real upstream entries: 宦 -> 啊, 啊 -> 聪.
        let once = try AppContentDecoder.decode("宦")
        XCTAssertEqual(once, "啊")
        XCTAssertEqual(try AppContentDecoder.decode(once), "聪", "Callers must tag restored content and never decode it a second time")
    }

    func testUnmappedUnicodeMarkupWhitespaceAndEmojiArePreservedExactly() throws {
        let unchanged = "<b>A &amp; B</b>\r\n e\u{301} 👩🏽‍🚀 𠀀\t123，。！？"
        XCTAssertEqual(try AppContentDecoder.decode(unchanged).utf8.map { $0 }, unchanged.utf8.map { $0 })
        XCTAssertEqual(try AppContentDecoder.decode(""), "")
    }

    func testBundledResourceMatchesPinnedUpstreamAndAll3760Pairs() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sfacg-content-dictionary", withExtension: "json"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "af5863d70776d9f14a236ee2229eecfb2fccdcb00f095404e412e5f3d7bd6831")
        let dictionary = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(dictionary.count, 3_760)
        XCTAssertEqual(Set(dictionary.keys), Set(dictionary.values), "The upstream table is a closed character permutation")
        let keys = dictionary.keys.sorted()
        XCTAssertEqual(try AppContentDecoder.decode(keys.joined()), keys.compactMap { dictionary[$0] }.joined())
    }

    func testMalformedOrNonCharacterDictionaryIsRejected() {
        for json in ["{}", "[]", "{\"甲\":3}", "{\"甲乙\":\"丙\"}", "{\"甲\":\"AB\"}", "{\"A\":\"甲\"}"] {
            XCTAssertThrowsError(try ContentSubstitutionDecoder(data: Data(json.utf8)))
        }
    }
}
