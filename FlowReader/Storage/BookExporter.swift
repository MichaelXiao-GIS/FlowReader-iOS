import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case epub = "EPUB", text = "TXT", markdown = "Markdown"
    var id: String { rawValue }
    var fileExtension: String { switch self { case .epub: "epub"; case .text: "txt"; case .markdown: "md" } }
}

enum BookExporter {
    static func export(book: Book, chapters: [ChapterContent], format: ExportFormat) throws -> URL {
        guard !chapters.isEmpty else { throw LibraryError.noChapters }
        let base = book.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "_")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(String(base.prefix(90)) + "." + format.fileExtension)
        let data: Data
        switch format {
        case .text:
            data = Data(([book.title, book.author] + chapters.map { "\n\($0.chapter.title)\n\n\($0.text)" }).joined(separator: "\n").utf8)
        case .markdown:
            data = Data((["# \(book.title)", book.author] + chapters.map { "\n## \($0.chapter.title)\n\n\($0.text)" }).joined(separator: "\n\n").utf8)
        case .epub:
            data = epub(book: book, chapters: chapters)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func epub(book: Book, chapters: [ChapterContent]) -> Data {
        let identifier = "urn:uuid:\(UUID().uuidString)"
        let modified = ISO8601DateFormatter().string(from: Date())
        let manifest = chapters.indices.map { "<item id=\"c\($0)\" href=\"chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"c\($0)\"/>" }.joined()
        let nav = chapters.enumerated().map { "<li><a href=\"chapter\($0.offset).xhtml\">\(xml($0.element.chapter.title))</a></li>" }.joined()
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
            ("OEBPS/content.opf", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"bookid\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"bookid\">\(identifier)</dc:identifier><dc:title>\(xml(book.title))</dc:title><dc:creator>\(xml(book.author))</dc:creator><dc:language>zh-CN</dc:language><meta property=\"dcterms:modified\">\(modified)</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\(manifest)</manifest><spine>\(spine)</spine></package>".utf8)),
            ("OEBPS/nav.xhtml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"zh-CN\"><head><title>目录</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>\(xml(book.title))</h1><ol>\(nav)</ol></nav></body></html>".utf8))
        ]
        for (index, content) in chapters.enumerated() {
            let body = content.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "<p>\(xml($0))</p>" }.joined(separator: "\n")
            let xhtml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"zh-CN\"><head><title>\(xml(content.chapter.title))</title><style>body{line-height:1.8;margin:1em;}p{text-indent:2em;}h1{font-size:1.4em;}</style></head><body><h1>\(xml(content.chapter.title))</h1>\(body)</body></html>"
            files.append(("OEBPS/chapter\(index).xhtml", Data(xhtml.utf8)))
        }
        return StoredZIP.archive(files)
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// A standards-compliant uncompressed ZIP writer. EPUB's mimetype remains the first entry.
enum StoredZIP {
    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data(), directory = Data()
        for (name, data) in files {
            let filename = Data(name.utf8), checksum = crc32(data), offset = UInt32(output.count)
            output.u32(0x04034b50); output.u16(20); output.u16(0x0800); output.u16(0)
            output.u16(0); output.u16(33); output.u32(checksum); output.u32(UInt32(data.count)); output.u32(UInt32(data.count))
            output.u16(UInt16(filename.count)); output.u16(0); output.append(filename); output.append(data)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(0x0800); directory.u16(0)
            directory.u16(0); directory.u16(33); directory.u32(checksum); directory.u32(UInt32(data.count)); directory.u32(UInt32(data.count))
            directory.u16(UInt16(filename.count)); directory.u16(0); directory.u16(0); directory.u16(0); directory.u16(0)
            directory.u32(0); directory.u32(offset); directory.append(filename)
        }
        let start = UInt32(output.count)
        output.append(directory)
        output.u32(0x06054b50); output.u16(0); output.u16(0); output.u16(UInt16(files.count)); output.u16(UInt16(files.count))
        output.u32(UInt32(directory.count)); output.u32(start); output.u16(0)
        return output
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0) }
        }
        return value ^ 0xffffffff
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(value & 0xffff)); u16(UInt16(value >> 16)) }
}
