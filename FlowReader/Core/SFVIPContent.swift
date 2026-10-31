import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import Vision

extension SFAPI {
    /// Fetches only the image the official server authorizes for this Web session.
    func vipContent(chapter: Chapter) async throws -> ChapterContent {
        guard hasWebSession() else { throw SFAPIError.server("请先使用官方网页登录，再读取已订阅章节。") }
        let generation = sessionGeneration()
        var components = URLComponents(string: "https://book.sfacg.com/ajax/ashx/common.ashx")!
        components.queryItems = ["op": "getChapPic", "tp": "true", "quick": "true", "cid": String(chapter.id), "nid": String(chapter.bookID), "font": "18", "lang": "", "w": "728"].map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = webRequest(url: components.url!, referer: chapter.officialURL)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, expectedGeneration: generation)
        guard response.mimeType?.hasPrefix("image/") == true, data.count > 512 else { throw SFAPIError.subscriptionRequired }
        let fingerprint = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard fingerprint != "412cee872b67ea5d6370e859686589c4" else { throw SFAPIError.subscriptionRequired }
        let recognition = Task.detached(priority: .userInitiated) { try VIPTextRecognizer.recognize(data) }
        let text = try await withTaskCancellationHandler {
            try await recognition.value
        } onCancel: {
            recognition.cancel()
        }
        try Task.checkCancellation()
        guard sessionGeneration() == generation else { throw CancellationError() }
        recordReadableChapter(chapter, generation: generation)
        var authorized = chapter
        authorized.confirmedPurchaseState = .available
        authorized.purchaseSessionGeneration = generation
        return ChapterContent(chapter: authorized, text: text, sourceFormatVersion: 2)
    }
}

/// The font=18 Web image protocol includes a phonetic band above each 38px text row.
/// Recognize all GIF frames, remove that annotation band, and process small image tiles
/// at readable resolution instead of giving Vision an entire downscaled chapter.
enum VIPTextRecognizer {
    static let rowHeight = 38
    static let topPadding = 5
    static let phoneticHeight = 15

    static func recognize(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw SFAPIError.invalidResponse }
        let count = CGImageSourceGetCount(source)
        guard (1...200).contains(count) else { throw SFAPIError.invalidResponse }
        var lines: [String] = []
        var confidences: [Float] = []
        var previousFrame: Data?
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                      frame.width > 0, frame.height > 0, frame.width * frame.height <= 40_000_000 else { throw SFAPIError.invalidResponse }
                let prepared = try prepare(frame, phoneticLayout: frame.width == 728)
                if let bytes = prepared.dataProvider?.data {
                    let digest = Data(SHA256.hash(data: bytes as Data))
                    if digest == previousFrame { return }
                    previousFrame = digest
                }
                for tile in tiles(width: prepared.width, height: prepared.height) {
                    try Task.checkCancellation()
                    guard let crop = prepared.cropping(to: tile.crop) else { continue }
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    recognition.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                    recognition.usesLanguageCorrection = true
                    recognition.minimumTextHeight = 0.006
                    try VNImageRequestHandler(cgImage: try enlarged(crop), options: [:]).perform([recognition])
                    let ordered = (recognition.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    for observation in ordered {
                        let center = tile.crop.minY + (1 - observation.boundingBox.midY) * tile.crop.height
                        guard tile.owned.contains(center), let candidate = observation.topCandidates(1).first else { continue }
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { lines.append(text); confidences.append(candidate.confidence) }
                    }
                }
            }
        }
        let raw = lines.joined(separator: "\n")
        guard !raw.isEmpty else { throw SFAPIError.emptyContent }
        if raw.count < 700 && ["请先订阅", "订阅后", "订阅本章", "点击订阅", "请先登录", "购买本章", "尚未订阅", "未购买"].contains(where: raw.contains) { throw SFAPIError.subscriptionRequired }
        let averageConfidence = confidences.reduce(0, +) / Float(max(1, confidences.count))
        let averageLength = Double(lines.reduce(0) { $0 + $1.count }) / Double(max(1, lines.count))
        guard averageConfidence >= 0.35, !(lines.count > 25 && averageLength < 5) else {
            throw SFAPIError.server("本章图片文字暂未能准确识别，请在官方页面查看。")
        }
        return paragraphs(from: lines)
    }

    struct Tile {
        let crop: CGRect
        let owned: Range<CGFloat>
    }

    static func tiles(width: Int, height: Int) -> [Tile] {
        stride(from: 0, to: height, by: 760).map { start in
            let end = min(height, start + 760)
            let cropStart = max(0, start - 38), cropEnd = min(height, end + 38)
            return Tile(crop: CGRect(x: 0, y: cropStart, width: width, height: cropEnd - cropStart), owned: CGFloat(start)..<CGFloat(end))
        }
    }

    static func prepare(_ image: CGImage, phoneticLayout: Bool) throws -> CGImage {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        return try pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw SFAPIError.invalidResponse }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = storage.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let annotation = phoneticLayout && (y < topPadding || (y - topPadding) % rowHeight < phoneticHeight)
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                    // Pale coloured background is not正文; preserve dark character strokes.
                    let paleColour = r > 185 && g > 165 && b > 150 && r - b > 12
                    if annotation || paleColour {
                        bytes[offset] = 255; bytes[offset + 1] = 255; bytes[offset + 2] = 255
                    }
                }
            }
            guard let result = context.makeImage() else { throw SFAPIError.invalidResponse }
            return result
        }
    }

    private static func enlarged(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width * 2, height: image.height * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw SFAPIError.invalidResponse }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        guard let result = context.makeImage() else { throw SFAPIError.invalidResponse }
        return result
    }

    static func paragraphs(from lines: [String]) -> String {
        var paragraphs: [String] = [], pending = ""
        for line in lines {
            pending += line
            if let last = line.last, "。！？!?…」』”）)".contains(last) {
                paragraphs.append(pending); pending = ""
            }
        }
        if !pending.isEmpty { paragraphs.append(pending) }
        return paragraphs.joined(separator: "\n")
    }
}
