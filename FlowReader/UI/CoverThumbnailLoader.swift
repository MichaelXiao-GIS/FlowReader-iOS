import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Quantized pixel sizes avoid retaining a new image for every fractional layout change.
struct CoverThumbnailRequest: Hashable, Sendable {
    static let maximumPixelDimension = 1_600
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int

    init?(url: URL?, width: CGFloat, height: CGFloat, scale: CGFloat) {
        guard let url, let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              width.isFinite, height.isFinite, scale.isFinite, width > 0, height > 0, scale > 0 else { return nil }
        self.url = url
        func pixels(_ points: CGFloat) -> Int {
            let value = min(CGFloat(Self.maximumPixelDimension), points * min(scale, 4))
            return min(Self.maximumPixelDimension, max(32, Int(ceil(value / 32)) * 32))
        }
        pixelWidth = pixels(width)
        pixelHeight = pixels(height)
    }
}

/// CGImage is immutable; only this final, immutable result crosses the loader actor.
final class CoverThumbnail: @unchecked Sendable {
    let image: CGImage
    var decodedByteCount: Int { image.bytesPerRow * image.height }
    init(image: CGImage) { self.image = image }
}

enum CoverThumbnailError: Error {
    case invalidResponse, oversizedFile, unsupportedImage
}

/// NSCache may evict earlier, but its cost limit alone isn't a strict ceiling. The
/// small ledger additionally removes least-recently-used entries before insertion.
final class CoverThumbnailCache {
    static let defaultCostLimit = 24 * 1_024 * 1_024
    private final class Key: NSObject {
        let request: CoverThumbnailRequest
        init(_ request: CoverThumbnailRequest) { self.request = request }
        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }
    private struct Entry { let cost: Int; var access: UInt64 }
    private let cache = NSCache<Key, CoverThumbnail>()
    private var entries: [CoverThumbnailRequest: Entry] = [:]
    private var clock: UInt64 = 0
    let costLimit: Int
    let countLimit: Int
    private(set) var currentCost = 0
    var count: Int { entries.count }

    init(costLimit: Int = defaultCostLimit, countLimit: Int = 96) {
        self.costLimit = max(0, costLimit)
        self.countLimit = max(0, countLimit)
        cache.totalCostLimit = self.costLimit
        cache.countLimit = self.countLimit
    }

    func image(for request: CoverThumbnailRequest) -> CoverThumbnail? {
        guard let image = cache.object(forKey: Key(request)) else {
            remove(request)
            return nil
        }
        clock &+= 1
        entries[request]?.access = clock
        return image
    }

    func insert(_ image: CoverThumbnail, for request: CoverThumbnailRequest) {
        remove(request)
        let cost = image.decodedByteCount
        guard cost > 0, cost <= costLimit, countLimit > 0 else { return }
        while currentCost > costLimit - cost || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[request] = Entry(cost: cost, access: clock)
        currentCost += cost
        cache.setObject(image, forKey: Key(request), cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
        entries.removeAll(keepingCapacity: false)
        currentCost = 0
    }

    private func remove(_ request: CoverThumbnailRequest) {
        cache.removeObject(forKey: Key(request))
        if let entry = entries.removeValue(forKey: request) { currentCost -= entry.cost }
    }
}

actor CoverThumbnailLoader {
    static let shared = CoverThumbnailLoader()
    typealias Operation = @Sendable (CoverThumbnailRequest) async throws -> CoverThumbnail
    private struct Pending {
        let id = UUID()
        var consumers: [UUID: CheckedContinuation<CoverThumbnail, Error>] = [:]
        var worker: Task<Void, Never>?
    }
    private let cache: CoverThumbnailCache
    private let operation: Operation
    private let maximumConcurrentLoads: Int
    private var pending: [CoverThumbnailRequest: Pending] = [:]
    private var queue: [CoverThumbnailRequest] = []
    private(set) var activeRequestCount = 0
    var pendingConsumerCount: Int { pending.values.reduce(0) { $0 + $1.consumers.count } }
    #if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
    #endif

    init(maximumConcurrentLoads: Int = 3, cacheCostLimit: Int = CoverThumbnailCache.defaultCostLimit,
         operation: @escaping Operation = { try await CoverThumbnailDecoder.load($0) }) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        self.operation = operation
        cache = CoverThumbnailCache(costLimit: cacheCostLimit)
    }

    deinit {
        #if canImport(UIKit)
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        #endif
    }

    func thumbnail(for request: CoverThumbnailRequest) async throws -> CoverThumbnail {
        try Task.checkCancellation()
        observeMemoryWarningsIfNeeded()
        if let cached = cache.image(for: request) { return cached }
        let consumer = UUID()
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if pending[request] == nil {
                    pending[request] = Pending()
                    queue.append(request)
                }
                pending[request]?.consumers[consumer] = continuation
                startWaitingLoads()
            }
        } onCancel: {
            Task { await self.cancel(consumer: consumer, request: request) }
        }
        try Task.checkCancellation()
        return image
    }

    func removeAllCachedImages() { cache.removeAll() }

    private func cancel(consumer: UUID, request: CoverThumbnailRequest) {
        guard let continuation = pending[request]?.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(throwing: CancellationError())
        if pending[request]?.consumers.isEmpty == true {
            // Remove immediately so a new caller never joins a cancelled worker.
            let worker = pending.removeValue(forKey: request)?.worker
            queue.removeAll { $0 == request }
            worker?.cancel()
        }
    }

    private func startWaitingLoads() {
        while activeRequestCount < maximumConcurrentLoads, !queue.isEmpty {
            let request = queue.removeFirst()
            guard let entry = pending[request], !entry.consumers.isEmpty else { continue }
            let id = entry.id
            let operation = operation
            activeRequestCount += 1
            pending[request]?.worker = Task.detached(priority: .utility) {
                let result: Result<CoverThumbnail, Error>
                do {
                    try Task.checkCancellation()
                    let image = try await operation(request)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch { result = .failure(error) }
                await self.finish(request: request, id: id, result: result)
            }
        }
    }

    private func finish(request: CoverThumbnailRequest, id: UUID, result: Result<CoverThumbnail, Error>) {
        activeRequestCount -= 1
        if let entry = pending[request], entry.id == id {
            pending.removeValue(forKey: request)
            if case let .success(image) = result { cache.insert(image, for: request) }
            for consumer in entry.consumers.values { consumer.resume(with: result) }
        }
        startWaitingLoads()
    }

    private func observeMemoryWarningsIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.removeAllCachedImages() }
        }
        #endif
    }
}

enum CoverThumbnailDecoder {
    static let maximumEncodedBytes = 12 * 1_024 * 1_024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    static func load(_ request: CoverThumbnailRequest) async throws -> CoverThumbnail {
        // A download task spools compressed originals to disk, not an in-memory Data cache.
        let (file, response) = try await session.download(from: request.url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CoverThumbnailError.invalidResponse
        }
        return try decode(file: file, for: request)
    }

    static func decode(file: URL, for request: CoverThumbnailRequest) throws -> CoverThumbnail {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard fileSize <= maximumEncodedBytes else { throw CoverThumbnailError.oversizedFile }
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw CoverThumbnailError.unsupportedImage
            }
            var sourceWidth = width.doubleValue
            var sourceHeight = height.doubleValue
            guard sourceWidth > 0, sourceHeight > 0, sourceWidth * sourceHeight <= 80_000_000 else {
                throw CoverThumbnailError.unsupportedImage
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if (5...8).contains(orientation) { swap(&sourceWidth, &sourceHeight) }
            let ratio = min(1, max(Double(request.pixelWidth) / sourceWidth, Double(request.pixelHeight) / sourceHeight))
            let maxPixels = min(CoverThumbnailRequest.maximumPixelDimension, Int(ceil(max(sourceWidth, sourceHeight) * ratio)))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw CoverThumbnailError.unsupportedImage
            }
            try Task.checkCancellation()
            return CoverThumbnail(image: image)
        }
    }
}
