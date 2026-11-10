import Foundation
import ZIPFoundation

enum EPUBError: LocalizedError {
    case invalid
    case noContent

    var errorDescription: String? {
        switch self {
        case .invalid: return "Die Datei ist keine gültige EPUB-Datei."
        case .noContent: return "Das Buch enthält keinen lesbaren Inhalt."
        }
    }
}

enum EPUBParser {
    static func importEPUB(at url: URL, libraryRoot: URL) throws -> Book {
        let fm = FileManager.default
        let id = UUID()
        let destination = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try fm.unzipItem(at: url, to: destination)
            var book = try parse(directory: destination)
            book.id = id
            if book.title.isEmpty {
                book.title = url.deletingPathExtension().lastPathComponent
            }
            return book
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    static func parse(directory: URL) throws -> Book {
        let containerURL = directory.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL) else { throw EPUBError.invalid }
        let container = ContainerParser()
        container.run(containerData)
        guard let opfPath = container.rootPath else { throw EPUBError.invalid }

        let opfURL = directory.appendingPathComponent(opfPath)
        guard let opfData = try? Data(contentsOf: opfURL) else { throw EPUBError.invalid }
        let opf = OPFParser()
        opf.run(opfData)

        let baseDirectory = (opfPath as NSString).deletingLastPathComponent

        func resolve(_ href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let withoutFragment = decoded.components(separatedBy: "#")[0]
            let joined = baseDirectory.isEmpty ? withoutFragment : baseDirectory + "/" + withoutFragment
            return normalize(joined)
        }

        var spine: [String] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let type = item.type.lowercased()
            guard type.contains("html") || type.contains("xml") else { continue }
            let path = resolve(item.href)
            let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
            if exists { spine.append(path) }
        }
        guard !spine.isEmpty else { throw EPUBError.noContent }

        var coverPath: String?
        if let coverID = opf.coverID, let item = opf.manifest[coverID], item.type.lowercased().hasPrefix("image") {
            coverPath = resolve(item.href)
        }
        if coverPath == nil, let item = opf.manifest.values.first(where: { $0.props.contains("cover-image") }) {
            coverPath = resolve(item.href)
        }
        if let path = coverPath,
           !FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) {
            coverPath = nil
        }

        var book = Book(
            title: opf.title ?? "",
            author: opf.creator ?? "",
            spine: spine,
            coverPath: coverPath
        )
        book.toc = tableOfContents(opf: opf, spine: spine, directory: directory, resolve: resolve)
        return book
    }

    // MARK: Inhaltsverzeichnis

    private static func tableOfContents(opf: OPFParser, spine: [String], directory: URL,
                                        resolve: (String) -> String) -> [TOCEntry] {
        var index: [String: Int] = [:]
        for (position, path) in spine.enumerated() where index[path] == nil {
            index[path] = position
        }

        var raw: [(String, String)] = []
        var tocPath = ""

        if let ncx = opf.manifest.values.first(where: { $0.type.lowercased() == "application/x-dtbncx+xml" }) {
            tocPath = resolve(ncx.href)
            if let data = try? Data(contentsOf: directory.appendingPathComponent(tocPath)) {
                let parser = NCXParser()
                parser.run(data)
                raw = parser.entries
            }
        }
        if raw.isEmpty, let nav = opf.manifest.values.first(where: { $0.props.contains("nav") }) {
            tocPath = resolve(nav.href)
            if let data = try? Data(contentsOf: directory.appendingPathComponent(tocPath)),
               let html = String(data: data, encoding: .utf8) {
                raw = navLinks(in: html)
            }
        }

        let tocDirectory = (tocPath as NSString).deletingLastPathComponent
        var result: [TOCEntry] = []
        var seen = Set<Int>()
        for (title, src) in raw {
            let decoded = src.removingPercentEncoding ?? src
            let file = decoded.components(separatedBy: "#")[0]
            guard !file.isEmpty else { continue }
            let path = normalize(tocDirectory.isEmpty ? file : tocDirectory + "/" + file)
            guard let chapter = index[path], !seen.contains(chapter) else { continue }
            let clean = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            seen.insert(chapter)
            result.append(TOCEntry(title: clean, chapter: chapter))
        }
        return result.sorted { $0.chapter < $1.chapter }
    }

    private static func navLinks(in html: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let text = html as NSString
        var result: [(String, String)] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let href = text.substring(with: match.range(at: 1))
            let label = text.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            result.append((label, href))
        }
        return result
    }

    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return parts.joined(separator: "/")
    }
}

private func localName(_ name: String) -> String {
    name.components(separatedBy: ":").last ?? name
}

final class ContainerParser: NSObject, XMLParserDelegate {
    var rootPath: String?

    func run(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if localName(elementName) == "rootfile", rootPath == nil {
            rootPath = attributeDict["full-path"]
        }
    }
}

final class OPFParser: NSObject, XMLParserDelegate {
    struct Item {
        var href: String
        var type: String
        var props: String
    }

    var manifest: [String: Item] = [:]
    var spine: [String] = []
    var title: String?
    var creator: String?
    var coverID: String?

    private var currentName = ""
    private var buffer = ""

    func run(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        switch name {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = Item(
                    href: href,
                    type: attributeDict["media-type"] ?? "",
                    props: attributeDict["properties"] ?? ""
                )
            }
        case "itemref":
            if let idref = attributeDict["idref"] { spine.append(idref) }
        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                coverID = content
            }
        case "title", "creator":
            currentName = name
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !currentName.isEmpty { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        guard name == currentName else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if name == "title", title == nil { title = text }
            if name == "creator", creator == nil { creator = text }
        }
        currentName = ""
        buffer = ""
    }
}

final class NCXParser: NSObject, XMLParserDelegate {
    var entries: [(String, String)] = []
    private var inLabel = false
    private var inText = false
    private var label = ""

    func run(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "navLabel":
            inLabel = true
            label = ""
        case "text":
            inText = inLabel
        case "content":
            if let src = attributeDict["src"] {
                entries.append((label, src))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { label += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(elementName) {
        case "navLabel": inLabel = false
        case "text": inText = false
        default: break
        }
    }
}
