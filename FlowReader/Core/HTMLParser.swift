import Foundation

enum HTMLParser {
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let result = matches(pattern, in: text).first, result.indices.contains(group) else { return nil }
        return result[group]
    }

    static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    static func plainText(_ html: String) -> String {
        var value = replace("<(script|style)\\b[^>]*>.*?</\\1>", in: html, with: "")
        value = replace("<br\\s*/?>|</p\\s*>|</li\\s*>", in: value, with: "\n")
        value = replace("<[^>]+>", in: value, with: "")
        value = decodeEntities(value).replacingOccurrences(of: "\r", with: "")
        value = replace("[ \\t]+\\n", in: value, with: "\n")
        value = replace("\\n{3,}", in: value, with: "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var value = text
        let named = ["&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&amp;": "&"]
        for (entity, decoded) in named { value = value.replacingOccurrences(of: entity, with: decoded) }
        for match in matches("&#(x[0-9a-f]+|[0-9]+);", in: value).reversed() {
            let token = match[1]
            let number = token.lowercased().hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            if let number, let scalar = UnicodeScalar(number) { value = value.replacingOccurrences(of: match[0], with: String(scalar)) }
        }
        return value
    }

    static func jsField(_ field: String, in text: String) -> String? {
        let key = NSRegularExpression.escapedPattern(for: field)
        if let result = first("(?:^|[,{\\s])['\"]?" + key + "['\"]?\\s*:\\s*['\"]([^'\"]*)['\"]", in: text) { return decodeEntities(result) }
        return first("(?:^|[,{\\s])['\"]?" + key + "['\"]?\\s*:\\s*([^,}\\s]+)", in: text)
    }

    static func chapterBody(_ html: String) -> String? {
        guard let body = first("<div\\b[^>]*\\bid=['\"]ChapterBody['\"][^>]*>(.*?)</div>", in: html) else { return nil }
        let result = plainText(body)
        return result.isEmpty ? nil : result
    }
}
