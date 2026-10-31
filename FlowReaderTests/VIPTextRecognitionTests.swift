import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import FlowReader

final class VIPTextRecognitionTests: XCTestCase {
    func testAnnotatedLongImageKeepsBeginningEndAndReadingOrder() throws {
        let lines = ["第一行，故事从这里开始。"] + (1...50).map { "这是一段用于测试的原创文字，第\($0)行。" } + ["最后一行，故事在这里结束。"]
        let image = makeImage(lines)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let text = try VIPTextRecognizer.recognize(data as Data)
        XCTAssertTrue(text.contains("故事从这里开始"))
        XCTAssertTrue(text.contains("故事在这里结束"))
        XCTAssertGreaterThan(text.count, 650, "Long chapters must not collapse into a few short fragments")
        XCTAssertFalse(text.contains("pinyin"), "The phonetic annotation band is not part of the正文")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "故事从这里开始")).lowerBound, try XCTUnwrap(text.range(of: "故事在这里结束")).lowerBound)
    }

    func testEveryGIFPageIsRecognizedInSequence() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for text in ["第一帧，这一页讲述清晨。", "第二帧，这一页讲述夜晚。"] {
            CGImageDestinationAddImage(destination, makeImage([text]), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let text = try VIPTextRecognizer.recognize(data as Data)
        XCTAssertTrue(text.contains("清晨"))
        XCTAssertTrue(text.contains("夜晚"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "清晨")).lowerBound, try XCTUnwrap(text.range(of: "夜晚")).lowerBound)
    }

    func testTileOwnershipCoversEveryImageRowExactlyOnce() {
        let tiles = VIPTextRecognizer.tiles(width: 728, height: 3200)
        for row in 0..<3200 {
            XCTAssertEqual(tiles.filter { $0.owned.contains(CGFloat(row) + 0.5) }.count, 1)
        }
        XCTAssertTrue(tiles.allSatisfy { $0.crop.height <= 836 })
    }

    private func makeImage(_ lines: [String]) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 728, height: 5 + lines.count * 38), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 728, height: 5 + lines.count * 38))
            for (index, line) in lines.enumerated() {
                let y = 5 + index * 38
                ("pinyin pinyin pinyin pinyin pinyin pinyin" as NSString).draw(at: CGPoint(x: 12, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                (line as NSString).draw(at: CGPoint(x: 12, y: y + 15), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            }
        }.cgImage!
    }
}
