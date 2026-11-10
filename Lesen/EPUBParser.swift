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

        return Book(
            title: opf.title ?? "",
            author: opf.creator ?? "",
            spine: spine,
            coverPath: coverPath
        )
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
