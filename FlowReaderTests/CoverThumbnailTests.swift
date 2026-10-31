import XCTest
import CoreGraphics
import ImageIO
@testable import FlowReader

final class CoverThumbnailTests: XCTestCase {
    func testRequestKeepsURLIdentityAndBoundsDynamicDisplaySizes() throws {
        let original = URL(string: "https://covers.example.test/book.jpg?edition=1")!
        let request = try XCTUnwrap(CoverThumbnailRequest(url: original, width: 100, height: 140, scale: 3))
        XCTAssertEqual(request.url, original)
        XCTAssertEqual(request.pixelWidth, 320)
        XCTAssertEqual(request.pixelHeight, 448)
        XCTAssertEqual(request, CoverThumbnailRequest(url: original, width: 100.2, height: 140.2, scale: 3))
        XCTAssertNotEqual(request, CoverThumbnailRequest(url: URL(string: "https://covers.example.test/book.jpg?edition=2"), width: 100, height: 140, scale: 3))
        XCTAssertNotEqual(request, CoverThumbnailRequest(url: original, width: 100, height: 140, scale: 2))
        let oversized = try XCTUnwrap(CoverThumbnailRequest(url: original, width: 10_000, height: 20_000, scale: 3))
        XCTAssertEqual(oversized.pixelWidth, 1_600)
        XCTAssertEqual(oversized.pixelHeight, 1_600)
        XCTAssertNil(CoverThumbnailRequest(url: URL(fileURLWithPath: "/private/image.jpg"), width: 100, height: 140, scale: 3))
        XCTAssertNil(CoverThumbnailRequest(url: URL(string: "https://user:password@example.test/image"), width: 100, height: 140, scale: 3))
        XCTAssertNil(CoverThumbnailRequest(url: original, width: .nan, height: 140, scale: 3))
        XCTAssertNil(CoverThumbnailRequest(url: original, width: 100, height: 0, scale: 3))
    }

    func testLargeOriginalBecomesSmallAspectFillThumbnail() throws {
        let file = try makeJPEG(width: 1_800, height: 2_700)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = try makeRequest(1)
        let thumbnail = try CoverThumbnailDecoder.decode(file: file, for: request)
        XCTAssertGreaterThanOrEqual(thumbnail.image.width, request.pixelWidth)
        XCTAssertGreaterThanOrEqual(thumbnail.image.height, request.pixelHeight)
        XCTAssertLessThanOrEqual(max(thumbnail.image.width, thumbnail.image.height), 480)
        XCTAssertLessThan(thumbnail.decodedByteCount, 1_024 * 1_024)
        XCTAssertLessThan(thumbnail.decodedByteCount, 1_800 * 2_700 * 4 / 10)
    }

    func testImageOrientationIsAppliedWithoutKeepingFullResolution() throws {
        let file = try makeJPEG(width: 900, height: 600, orientation: 6)
        defer { try? FileManager.default.removeItem(at: file) }
        let thumbnail = try CoverThumbnailDecoder.decode(file: file, for: makeRequest(1))
        XCTAssertLessThan(thumbnail.image.width, thumbnail.image.height)
        XCTAssertLessThanOrEqual(max(thumbnail.image.width, thumbnail.image.height), 480)
    }

    func testMalformedAndOversizedEncodedFilesAreRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("<html>Not an image</html>".utf8).write(to: file)
        XCTAssertThrowsError(try CoverThumbnailDecoder.decode(file: file, for: makeRequest(1)))
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CoverThumbnailDecoder.maximumEncodedBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try CoverThumbnailDecoder.decode(file: file, for: makeRequest(1))) { error in
            guard case CoverThumbnailError.oversizedFile = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testCacheNeverRetainsMoreThanItsCostOrCountBudget() throws {
        let thumbnail = try makeThumbnail()
        let cost = thumbnail.decodedByteCount
        let costBounded = CoverThumbnailCache(costLimit: cost * 2, countLimit: 20)
        let countBounded = CoverThumbnailCache(costLimit: cost * 20, countLimit: 2)
        for id in 0..<100 {
            let request = try makeRequest(id)
            costBounded.insert(thumbnail, for: request)
            countBounded.insert(thumbnail, for: request)
            XCTAssertLessThanOrEqual(costBounded.currentCost, cost * 2)
            XCTAssertLessThanOrEqual(costBounded.count, 2)
            XCTAssertLessThanOrEqual(countBounded.count, 2)
        }
        let tooSmall = CoverThumbnailCache(costLimit: cost - 1)
        let request = try makeRequest(1)
        tooSmall.insert(thumbnail, for: request)
        XCTAssertNil(tooSmall.image(for: request))
        XCTAssertEqual(tooSmall.currentCost, 0)
        costBounded.removeAll()
        XCTAssertEqual(costBounded.currentCost, 0)
        XCTAssertEqual(costBounded.count, 0)
        XCTAssertNil(costBounded.image(for: try makeRequest(99)))
    }

    func testSharedRequestSurvivesOneConsumerCancellationAndUsesCache() async throws {
        let gate = ThumbnailWorkGate(image: try makeThumbnail())
        let loader = CoverThumbnailLoader(operation: { try await gate.load($0) })
        let request = try makeRequest(1)
        let first = Task { try await loader.thumbnail(for: request) }
        let second = Task { try await loader.thumbnail(for: request) }
        try await waitUntil { await loader.pendingConsumerCount == 2 }
        try await waitUntil { await gate.startedCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("The cancelled consumer must not receive an image") }
        catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        let cancellations = await gate.cancelledCount
        XCTAssertEqual(cancellations, 0)
        await gate.releaseAll()
        let surviving = try await second.value
        let cached = try await loader.thumbnail(for: request)
        XCTAssertTrue(surviving === cached)
        let starts = await gate.startedCount
        XCTAssertEqual(starts, 1)
    }

    func testLastConsumerCancellationStopsWorkAndDoesNotPoisonLaterRequest() async throws {
        let gate = ThumbnailWorkGate(image: try makeThumbnail())
        let loader = CoverThumbnailLoader(operation: { try await gate.load($0) })
        let request = try makeRequest(1)
        let first = Task { try await loader.thumbnail(for: request) }
        try await waitUntil { await gate.startedCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled request succeeded") }
        catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        try await waitUntil { await gate.cancelledCount == 1 }
        let replacement = Task { try await loader.thumbnail(for: request) }
        try await waitUntil { await gate.startedCount == 2 }
        await gate.releaseAll()
        _ = try await replacement.value
        let active = await loader.activeRequestCount
        XCTAssertEqual(active, 0)
    }

    func testConcurrentLoadsAreBoundedAndQueuedCancellationDoesNotFetch() async throws {
        let gate = ThumbnailWorkGate(image: try makeThumbnail())
        let loader = CoverThumbnailLoader(maximumConcurrentLoads: 2, operation: { try await gate.load($0) })
        let firstRequest = try makeRequest(1)
        let secondRequest = try makeRequest(2)
        let queuedRequest = try makeRequest(3)
        let first = Task { try await loader.thumbnail(for: firstRequest) }
        let second = Task { try await loader.thumbnail(for: secondRequest) }
        try await waitUntil { await gate.startedCount == 2 }
        let queued = Task { try await loader.thumbnail(for: queuedRequest) }
        try await waitUntil { await loader.pendingConsumerCount == 3 }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled queued request succeeded") }
        catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        await gate.releaseAll()
        _ = try await (first.value, second.value)
        let starts = await gate.startedCount
        let peak = await gate.maximumActive
        let requested = await gate.requestedURLs
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(peak, 2)
        XCTAssertFalse(requested.contains(queuedRequest.url))
    }

    private func makeRequest(_ id: Int) throws -> CoverThumbnailRequest {
        try XCTUnwrap(CoverThumbnailRequest(url: URL(string: "https://covers.example.test/\(id).jpg"), width: 100, height: 140, scale: 3))
    }

    private func makeThumbnail() throws -> CoverThumbnail {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        return CoverThumbnail(image: try XCTUnwrap(context.makeImage()))
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverThumbnailError.unsupportedImage }
        return file
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the image loader")
        throw URLError(.timedOut)
    }
}

private actor ThumbnailWorkGate {
    let image: CoverThumbnail
    private var continuations: [UUID: CheckedContinuation<CoverThumbnail, Error>] = [:]
    private var active = 0
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0
    private(set) var maximumActive = 0
    private(set) var requestedURLs: [URL] = []

    init(image: CoverThumbnail) { self.image = image }

    func load(_ request: CoverThumbnailRequest) async throws -> CoverThumbnail {
        let id = UUID()
        startedCount += 1
        active += 1
        maximumActive = max(maximumActive, active)
        requestedURLs.append(request.url)
        defer { active -= 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuations[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseAll() {
        let waiting = continuations.values
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: image) }
    }

    private func cancel(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        cancelledCount += 1
        continuation.resume(throwing: CancellationError())
    }
}
