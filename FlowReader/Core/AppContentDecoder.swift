import Foundation

/// SFACG App content uses a character substitution even when isContentEncrypted is false.
/// The GPLv3 dictionary and single-pass behavior come from SFNovel-ReaderProject
/// commit 3fa06a01db2a98585fa3abb77c4be9af0bcb856e, adapters/storage/settings.rs.
enum AppContentDecoder {
    static let formatVersion = 4
    private static let bundled: Result<ContentSubstitutionDecoder, Error> = Result {
        guard let url = Bundle.main.url(forResource: "sfacg-content-dictionary", withExtension: "json") else {
            throw SFAPIError.server("正文还原字典缺失，请重新安装完整版本后重试。")
        }
        let decoder = try ContentSubstitutionDecoder(data: Data(contentsOf: url))
        guard decoder.count == 3_760 else {
            throw SFAPIError.server("正文还原字典不完整，请重新安装完整版本后重试。")
        }
        return decoder
    }

    /// Apply only to a fresh App response or an explicitly tagged version-3 App cache.
    /// This substitution is not idempotent; never run it on version-4, Web, OCR or local text.
    static func decode(_ text: String) throws -> String {
        try bundled.get().decode(text)
    }
}

struct ContentSubstitutionDecoder: Sendable {
    private let mapping: [Unicode.Scalar: Unicode.Scalar]
    var count: Int { mapping.count }

    init(data: Data) throws {
        let entries = try JSONDecoder().decode([String: String].self, from: data)
        guard !entries.isEmpty else { throw SFAPIError.invalidResponse }
        var mapping: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (source, destination) in entries {
            guard source.unicodeScalars.count == 1, destination.unicodeScalars.count == 1,
                  let source = source.unicodeScalars.first, let destination = destination.unicodeScalars.first,
                  Self.isHan(source), Self.isHan(destination) else { throw SFAPIError.invalidResponse }
            mapping[source] = destination
        }
        self.mapping = mapping
    }

    func decode(_ text: String) -> String {
        // Build a new scalar sequence. Repeated String.replacingOccurrences would cascade
        // through the dictionary and turn an already restored character into another one.
        var output = String.UnicodeScalarView()
        output.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars { output.append(mapping[scalar] ?? scalar) }
        return String(output)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
