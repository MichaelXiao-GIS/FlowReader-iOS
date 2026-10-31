import XCTest
import simd
@testable import FlowReader

final class ReaderCurlGeometryTests: XCTestCase {
    private let size = CGSize(width: 400, height: 700)

    func testGrabbedPointTracksTheFingerInBothAxes() {
        for (anchor, finger) in [(CGPoint(x: 370, y: 120), CGPoint(x: 105, y: 295)),
                                 (CGPoint(x: 370, y: 610), CGPoint(x: 105, y: 405))] {
            let geometry = ReaderCurlGeometry(pageSize: size, anchor: anchor, finger: finger)
            let grabbed = geometry.sample(anchor)
            XCTAssertEqual(grabbed.position.x, Float(finger.x), accuracy: 0.01)
            XCTAssertEqual(grabbed.position.y, Float(finger.y), accuracy: 0.01)
            XCTAssertGreaterThan(geometry.radius, 20)
        }
    }

    func testNoGestureIsExactlyFlatAndCompletedTurnIsExactlyReflected() {
        let anchor = CGPoint(x: 360, y: 400)
        let rest = ReaderCurlGeometry(pageSize: size, anchor: anchor, finger: anchor)
        let complete = ReaderCurlGeometry(pageSize: size, anchor: anchor, finger: CGPoint(x: -360, y: 400))
        XCTAssertEqual(complete.progress, 1)
        XCTAssertEqual(complete.radius, 0)
        for x in stride(from: 0, through: 400, by: 20) {
            let p = CGPoint(x: x, y: 240)
            XCTAssertEqual(rest.sample(p).position, SIMD3(Float(x), 240, 0))
            XCTAssertEqual(complete.sample(p).position.x, -Float(x), accuracy: 0.001)
            XCTAssertEqual(complete.sample(p).position.y, 240, accuracy: 0.001)
            XCTAssertEqual(complete.sample(p).position.z, 0, accuracy: 0.001)
        }
    }

    func testObliqueDragProducesCurvatureRatherThanARigidStraightFold() {
        let geometry = ReaderCurlGeometry(pageSize: size, anchor: CGPoint(x: 370, y: 610), finger: CGPoint(x: 105, y: 405))
        var lifted = 0
        var curved = 0
        for y in stride(from: 0, through: 700, by: 10) { for x in stride(from: 0, through: 400, by: 10) {
            let sample = geometry.sample(CGPoint(x: x, y: y))
            XCTAssertTrue(sample.position.x.isFinite && sample.position.y.isFinite && sample.position.z.isFinite)
            if sample.position.z > 1 { lifted += 1 }
            if sample.angle > 0.05 && sample.angle < .pi - 0.05 { curved += 1 }
        } }
        XCTAssertGreaterThan(lifted, 100)
        XCTAssertGreaterThan(curved, 100)
        let top = geometry.sample(CGPoint(x: 310, y: 100))
        let bottom = geometry.sample(CGPoint(x: 310, y: 600))
        XCTAssertNotEqual(top.angle, bottom.angle)
    }

    func testShortOrReversedGestureCancelsAndIntentionalSwipeCommits() {
        XCTAssertFalse(ReaderCurlGeometry.shouldCommit(translation: CGPoint(x: -12, y: 70), velocity: .zero, pageWidth: 400, direction: 1))
        XCTAssertTrue(ReaderCurlGeometry.shouldCommit(translation: CGPoint(x: -150, y: 40), velocity: .zero, pageWidth: 400, direction: 1))
        XCTAssertFalse(ReaderCurlGeometry.shouldCommit(translation: CGPoint(x: -150, y: 40), velocity: CGPoint(x: 700, y: 0), pageWidth: 400, direction: 1))
        XCTAssertTrue(ReaderCurlGeometry.shouldCommit(translation: CGPoint(x: 30, y: -10), velocity: CGPoint(x: 900, y: 0), pageWidth: 400, direction: -1))
    }

    func testSpreadUsesTheCorrectFrontBackAndUnderlyingPagesInBothDirections() throws {
        let next = try XCTUnwrap(ReaderCurlPageTurn(index: 0, direction: 1, pageCount: 7, doublePage: true))
        XCTAssertEqual(next.target, 2)
        XCTAssertEqual(next.front, 1)
        XCTAssertEqual(next.back, 2)
        XCTAssertEqual(next.basePages, [0, 3])
        let previous = try XCTUnwrap(ReaderCurlPageTurn(index: 4, direction: -1, pageCount: 7, doublePage: true))
        XCTAssertEqual(previous.target, 2)
        XCTAssertEqual(previous.front, 4)
        XCTAssertEqual(previous.back, 3)
        XCTAssertEqual(previous.basePages, [2, 5])
        let final = try XCTUnwrap(ReaderCurlPageTurn(index: 4, direction: 1, pageCount: 7, doublePage: true))
        XCTAssertEqual(final.basePages, [4, 7], "An odd final spread has one deliberate blank leaf")
        XCTAssertNil(ReaderCurlPageTurn(index: 6, direction: 1, pageCount: 7, doublePage: true))
        XCTAssertNil(ReaderCurlPageTurn(index: 0, direction: -1, pageCount: 7, doublePage: true))
    }

    func testShaderUniformAlignmentMatchesFiveFloatVectors() {
        XCTAssertEqual(MemoryLayout<ReaderCurlUniforms>.stride, 80)
        XCTAssertEqual(MemoryLayout<ReaderCurlUniforms>.alignment, 16)
    }
}
