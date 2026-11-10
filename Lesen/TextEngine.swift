import UIKit

// Der Lesemotor: wandelt die XHTML-Kapitel eines EPUB in nativen iOS-Text um und teilt ihn
// mit TextKit in Seiten. Jede Seite wird direkt gezeichnet, deshalb gibt es beim Umblättern
// keine Ladezeit.

// MARK: - CSS

struct CSSProps {
    var italic: Bool?
    var bold: Bool?
    var align: NSTextAlignment?
    var indent: CGFloat?
    var marginTop: CGFloat?
    var marginBottom: CGFloat?
    var marginLeft: CGFloat?
    var scale: CGFloat?
    var superscript: Bool?
    var uppercase: Bool?
    var smallCaps: Bool?
    var pageBreak: Bool?
    var hidden: Bool?

    mutating func merge(_ other: CSSProps) {
        if let v = other.italic { italic = v }
        if let v = other.bold { bold = v }
        if let v = other.align { align = v }
        if let v = other.indent { indent = v }
        if let v = other.marginTop { marginTop = v }
        if let v = other.marginBottom { marginBottom = v }
        if let v = other.marginLeft { marginLeft = v }
        if let v = other.scale { scale = v }
        if let v = other.superscript { superscript = v }
        if let v = other.uppercase { uppercase = v }
        if let v = other.smallCaps { smallCaps = v }
        if let v = other.pageBreak { pageBreak = v }
        if let v = other.hidden { hidden = v }
    }
}

struct StyleSheet {
    private var rules: [String: CSSProps] = [:]

    /// Längenangabe in „em" umrechnen.
    static func length(_ raw: String) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value == "0" { return 0 }
        let units: [(String, CGFloat)] = [("rem", 1), ("em", 1), ("px", 1.0 / 16), ("pt", 1.0 / 12), ("%", 0.1)]
        for (unit, factor) in units where value.hasSuffix(unit) {
            if let number = Double(value.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) {
                return CGFloat(number) * factor
            }
            return nil
        }
        return nil
    }

    static func fontScale(_ raw: String) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch value {
        case "xx-small": return 0.6
        case "x-small": return 0.7
        case "small", "smaller": return 0.85
        case "medium": return 1
        case "large", "larger": return 1.2
        case "x-large": return 1.5
        case "xx-large": return 1.9
        default: break
        }
        if value.hasSuffix("%"), let number = Double(value.dropLast()) { return CGFloat(number) / 100 }
        if value.hasSuffix("rem"), let number = Double(value.dropLast(3)) { return CGFloat(number) }
        if value.hasSuffix("em"), let number = Double(value.dropLast(2)) { return CGFloat(number) }
        if value.hasSuffix("px"), let number = Double(value.dropLast(2)) { return CGFloat(number) / 16 }
        if value.hasSuffix("pt"), let number = Double(value.dropLast(2)) { return CGFloat(number) / 12 }
        return nil
    }

    static func parse(declarations: String) -> CSSProps {
        var props = CSSProps()
        for declaration in declarations.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch name {
            case "font-style":
                props.italic = value == "italic" || value == "oblique"
            case "font-weight":
                if let number = Int(value) {
                    props.bold = number >= 600
                } else {
                    props.bold = value == "bold" || value == "bolder"
                }
            case "text-align":
                switch value {
                case "left", "start": props.align = .left
                case "right", "end": props.align = .right
                case "center": props.align = .center
                case "justify": props.align = .justified
                default: break
                }
            case "text-indent":
                if let v = length(value) { props.indent = max(0, v) }
            case "margin-top":
                if let v = length(value) { props.marginTop = max(0, v) }
            case "margin-bottom":
                if let v = length(value) { props.marginBottom = max(0, v) }
            case "margin-left", "padding-left":
                if let v = length(value), v > 0 { props.marginLeft = (props.marginLeft ?? 0) + v }
            case "margin":
                let values = value.split(separator: " ").map { length(String($0)) }
                if let first = values.first, let top = first {
                    props.marginTop = max(0, top)
                    props.marginBottom = max(0, top)
                }
                if values.count >= 3, let bottom = values[2] {
                    props.marginBottom = max(0, bottom)
                }
            case "font-size":
                if let v = fontScale(value) { props.scale = v }
            case "vertical-align":
                if value == "super" {
                    props.superscript = true
                } else if value.hasSuffix("%"), let number = Double(value.dropLast()), number >= 15 {
                    props.superscript = true
                }
            case "text-transform":
                props.uppercase = value == "uppercase"
            case "font-variant":
                props.smallCaps = value.contains("small-caps")
            case "page-break-before", "break-before":
                props.pageBreak = ["always", "page", "left", "right"].contains(value)
            case "display":
                if value == "none" { props.hidden = true }
            default:
                break
            }
        }
        return props
    }

    mutating func add(css: String) {
        let cleaned = css.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        for chunk in cleaned.components(separatedBy: "}") {
            let parts = chunk.components(separatedBy: "{")
            guard parts.count == 2 else { continue }
            let selectors = parts[0]
            if selectors.contains("@") { continue }
            let props = StyleSheet.parse(declarations: parts[1])
            for selector in selectors.split(separator: ",") {
                let pieces = selector.split(whereSeparator: { $0 == " " || $0 == ">" || $0 == "\n" || $0 == "\t" || $0 == "+" })
                guard var last = pieces.last.map(String.init) else { continue }
                if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
                let key = last.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !key.contains("["), !key.contains("#") else { continue }
                let normalized: String
                if let dot = key.firstIndex(of: ".") {
                    normalized = key[..<dot].lowercased() + String(key[dot...])
                } else {
                    normalized = key.lowercased()
                }
                var existing = rules[normalized] ?? CSSProps()
                existing.merge(props)
                rules[normalized] = existing
            }
        }
    }

    func props(tag: String, classes: [String], inline: String?) -> CSSProps {
        var result = CSSProps()
        if let rule = rules[tag] { result.merge(rule) }
        for name in classes {
            if let rule = rules["." + name] { result.merge(rule) }
            if let rule = rules[tag + "." + name] { result.merge(rule) }
        }
        if let inline, !inline.isEmpty {
            result.merge(StyleSheet.parse(declarations: inline))
        }
        return result
    }
}

// MARK: - Schrift

struct TextConfig {
    var font: ReadingFont
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var textColor: UIColor
    var contentSize: CGSize
}

final class FontBook {
    private var cache: [String: UIFont] = [:]
    private let family: ReadingFont

    init(family: ReadingFont) {
        self.family = family
    }

    func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let key = "\(size)-\(bold)-\(italic)"
        if let cached = cache[key] { return cached }

        var descriptor: UIFontDescriptor
        switch family {
        case .newYork:
            let system = UIFont.systemFont(ofSize: size).fontDescriptor
            descriptor = system.withDesign(.serif) ?? system
        case .sans:
            descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        default:
            descriptor = UIFontDescriptor(fontAttributes: [.family: family.familyName])
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) {
            descriptor = styled
        }
        let font = UIFont(descriptor: descriptor, size: size)
        cache[key] = font
        return font
    }
}

// MARK: - XHTML → Text

final class ChapterBuilder: NSObject, XMLParserDelegate {
    private struct Inline {
        var italic = false
        var bold = false
        var scale: CGFloat = 1
        var superscript = false
        var uppercase = false
        var smallCaps = false
        var hidden = false
    }

    private struct Block {
        var align: NSTextAlignment?
        var indent: CGFloat = 0
        var left: CGFloat = 0
        var heading = false
    }

    private struct Frame {
        var name: String
        var isBlock: Bool
        var inline: Inline
        var block: Block
        var marginBottom: CGFloat
        var startLength: Int
    }

    private static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li", "ul", "ol", "section",
        "article", "body", "figure", "figcaption", "hr", "tr", "table", "pre", "dd", "dt", "dl",
        "header", "footer", "aside", "nav", "address", "center"
    ]
    private static let skippedTags: Set<String> = ["head", "script", "style", "title"]
    private static let headingScale: [String: CGFloat] = [
        "h1": 1.3, "h2": 1.2, "h3": 1.1, "h4": 1.06, "h5": 1, "h6": 1
    ]
    private static let entities: [String: String] = [
        "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "bdquo": "„", "sbquo": "‚",
        "shy": "\u{00AD}", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "euro": "€",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "agrave": "à", "aacute": "á", "acirc": "â",
        "ccedil": "ç", "iuml": "ï", "icirc": "î", "ocirc": "ô", "ucirc": "û", "ugrave": "ù",
        "ntilde": "ñ", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "middot": "·",
        "bull": "•", "times": "×", "frac12": "½", "sect": "§", "para": "¶", "dagger": "†",
        "iexcl": "¡", "iquest": "¿", "aring": "å", "oslash": "ø", "aelig": "æ", "oelig": "œ"
    ]

    private let config: TextConfig
    private let sheet: StyleSheet
    private let fileURL: URL
    private let fonts: FontBook

    private let output = NSMutableAttributedString()
    private let buffer = NSMutableAttributedString()
    private var frames: [Frame] = []
    private var skipDepth = 0
    private var pendingSpace: CGFloat = 0
    private var paragraphBlock = Block()
    private var paragraphSpace: CGFloat = 0
    private var bufferHasLargeImage = false

    init(config: TextConfig, sheet: StyleSheet, fileURL: URL) {
        self.config = config
        self.sheet = sheet
        self.fileURL = fileURL
        self.fonts = FontBook(family: config.font)
    }

    static func build(fileURL: URL, config: TextConfig, sheet: StyleSheet) -> NSAttributedString {
        let builder = ChapterBuilder(config: config, sheet: sheet, fileURL: fileURL)
        return builder.run()
    }

    private func run() -> NSAttributedString {
        guard let data = try? Data(contentsOf: fileURL) else {
            return NSAttributedString(string: " ", attributes: attributes(Inline()))
        }
        var source = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        source = ChapterBuilder.replaceEntities(in: source)

        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.parse()
        flushParagraph()

        if output.length == 0 {
            // Kein gültiges XML: Tags grob entfernen und als einfachen Text setzen.
            let plain = source
                .replacingOccurrences(of: "<(head|style|script)[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "</(p|div|h[1-6]|li)>", with: "\n", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for line in plain.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                paragraphBlock = Block(align: nil, indent: 1.2, left: 0, heading: false)
                paragraphSpace = 0
                buffer.append(NSAttributedString(string: trimmed, attributes: attributes(Inline())))
                flushParagraph()
            }
        }
        if output.length == 0 {
            output.append(NSAttributedString(string: " ", attributes: attributes(Inline())))
        }
        // Abschließenden Zeilenumbruch entfernen, damit keine leere Schlussseite entsteht.
        while output.length > 1, output.string.hasSuffix("\n") || output.string.hasSuffix("\u{0C}") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    private static func replaceEntities(in source: String) -> String {
        guard source.contains("&") else { return source }
        guard let regex = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);") else { return source }
        let text = source as NSString
        let result = NSMutableString(string: source)
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            let name = text.substring(with: match.range(at: 1))
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) { continue }
            result.replaceCharacters(in: match.range, with: entities[name] ?? "")
        }
        return result as String
    }

    // MARK: Attribute

    private func normalize(scale: CGFloat) -> CGFloat {
        // Viele Verlage setzen den Fließtext auf z. B. 0.88em. Das soll die gewählte Schriftgröße nicht verkleinern.
        if scale >= 0.8 && scale <= 1.05 { return 1 }
        return min(1.8, max(0.7, scale / 0.9))
    }

    private func attributes(_ inline: Inline) -> [NSAttributedString.Key: Any] {
        var size = config.fontSize * inline.scale
        if inline.superscript { size *= 0.72 }
        if inline.smallCaps { size *= 0.84 }
        var result: [NSAttributedString.Key: Any] = [
            .font: fonts.font(size: size, bold: inline.bold, italic: inline.italic),
            .foregroundColor: config.textColor
        ]
        if inline.superscript {
            result[.baselineOffset] = config.fontSize * 0.34
        }
        return result
    }

    private var currentInline: Inline { frames.last?.inline ?? Inline() }
    private var currentBlock: Block { frames.last?.block ?? Block() }
    private var lineUnit: CGFloat { config.lineHeight }

    private func beginParagraphIfNeeded() {
        if buffer.length == 0 {
            paragraphBlock = currentBlock
            paragraphSpace = pendingSpace
            pendingSpace = 0
            bufferHasLargeImage = false
        }
    }

    private func flushParagraph() {
        guard buffer.length > 0 else { return }
        // Leerzeichen am Ende entfernen
        while buffer.length > 0, buffer.string.hasSuffix(" ") {
            buffer.deleteCharacters(in: NSRange(location: buffer.length - 1, length: 1))
        }
        guard buffer.length > 0 else { return }

        let style = NSMutableParagraphStyle()
        let alignment = paragraphBlock.align ?? (paragraphBlock.heading ? .center : .justified)
        style.alignment = alignment
        let left = min(paragraphBlock.left, 4) * config.fontSize
        style.headIndent = left
        let wantsIndent = alignment == .justified || alignment == .left
        style.firstLineHeadIndent = left + (wantsIndent ? min(paragraphBlock.indent, 3) * config.fontSize : 0)
        let space = min(paragraphSpace, 9) * config.fontSize
        style.paragraphSpacingBefore = min(space, config.contentSize.height * 0.35)
        style.lineSpacing = bufferHasLargeImage ? 0 : max(0, (config.lineHeight - 1.2) * config.fontSize)
        style.hyphenationFactor = (alignment == .justified && !paragraphBlock.heading) ? 1 : 0
        style.lineBreakMode = .byWordWrapping

        buffer.append(NSAttributedString(string: "\n", attributes: attributes(Inline())))
        buffer.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: buffer.length))
        output.append(buffer)
        buffer.deleteCharacters(in: NSRange(location: 0, length: buffer.length))
    }

    private func appendImage(source: String) {
        let decoded = source.removingPercentEncoding ?? source
        let url = URL(fileURLWithPath: decoded, relativeTo: fileURL.deletingLastPathComponent()).standardizedFileURL
        guard let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 else { return }

        let maxWidth = max(40, config.contentSize.width - currentBlock.left * config.fontSize)
        let maxHeight = max(40, config.contentSize.height - 12)
        let factor = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
        let size = CGSize(width: floor(image.size.width * factor), height: floor(image.size.height * factor))

        var display = image
        if image.size.width > size.width * 3.2 {
            display = image.preparingThumbnail(of: CGSize(width: size.width * 3, height: size.height * 3)) ?? image
        }
        let attachment = NSTextAttachment()
        attachment.image = display
        attachment.bounds = CGRect(origin: .zero, size: size)

        beginParagraphIfNeeded()
        if size.height > config.fontSize * 2.5 {
            bufferHasLargeImage = true
            if paragraphBlock.align == nil { paragraphBlock.align = .center }
        }
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes(attributes(Inline()), range: NSRange(location: 0, length: piece.length))
        buffer.append(piece)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        if skipDepth > 0 || ChapterBuilder.skippedTags.contains(name) {
            skipDepth += 1
            return
        }

        let classes = (attributeDict["class"] ?? "").split(separator: " ").map(String.init)
        var props = CSSProps()
        // Vorgaben je Tag, die das Stylesheet des Buchs überschreiben darf
        switch name {
        case "em", "i", "cite", "dfn": props.italic = true
        case "strong", "b": props.bold = true
        case "sup": props.superscript = true
        case "small": props.scale = 0.85
        case "blockquote":
            props.marginLeft = 1.4
            props.marginTop = 0.6
            props.marginBottom = 0.6
        case "li": props.marginLeft = 1.2
        case "h1", "h2", "h3", "h4", "h5", "h6":
            props.bold = true
            props.scale = ChapterBuilder.headingScale[name]
            props.marginTop = 1.2
            props.marginBottom = 0.8
        default: break
        }
        let fromSheet = sheet.props(tag: name, classes: classes, inline: attributeDict["style"])
        let sheetKnowsParagraph = fromSheet.indent != nil || fromSheet.marginTop != nil || fromSheet.marginBottom != nil
        props.merge(fromSheet)
        if name == "p" && !sheetKnowsParagraph {
            // Buch ohne eigene Absatzregeln: klassischer Erstzeileneinzug
            props.indent = 1.2
        }

        let isBlock = ChapterBuilder.blockTags.contains(name)
        let parentInline = currentInline
        let parentBlock = currentBlock

        if isBlock {
            flushParagraph()
            pendingSpace = max(pendingSpace, props.marginTop ?? 0)
            if props.pageBreak == true, output.length > 0 {
                output.append(NSAttributedString(string: "\u{0C}", attributes: attributes(Inline())))
                pendingSpace = 0
            }
        }

        var inline = parentInline
        if let v = props.italic { inline.italic = v }
        if let v = props.bold { inline.bold = v }
        if let v = props.scale { inline.scale = parentInline.scale * (isBlock || name == "span" || name == "small" ? normalize(scale: v) : v) }
        if let v = props.superscript { inline.superscript = v }
        if let v = props.uppercase { inline.uppercase = v }
        if let v = props.smallCaps { inline.smallCaps = v }
        if props.hidden == true { inline.hidden = true }

        var block = parentBlock
        if isBlock {
            if let v = props.align { block.align = v }
            if let v = props.indent { block.indent = v }
            block.left = parentBlock.left + (props.marginLeft ?? 0)
            if ChapterBuilder.headingScale[name] != nil { block.heading = true }
        }

        frames.append(Frame(name: name, isBlock: isBlock, inline: inline, block: block,
                            marginBottom: props.marginBottom ?? 0, startLength: output.length + buffer.length))

        if inline.hidden { return }

        switch name {
        case "br":
            if buffer.length == 0 {
                pendingSpace += lineUnit
            } else {
                buffer.append(NSAttributedString(string: "\u{2028}", attributes: attributes(inline)))
            }
        case "img":
            if let source = attributeDict["src"] { appendImage(source: source) }
        case "image":
            if let source = attributeDict["xlink:href"] ?? attributeDict["href"] { appendImage(source: source) }
        case "hr":
            beginParagraphIfNeeded()
            paragraphBlock.align = .center
            paragraphSpace = max(paragraphSpace, 0.8)
            buffer.append(NSAttributedString(string: "* * *", attributes: attributes(inline)))
            flushParagraph()
            pendingSpace = max(pendingSpace, 0.8)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        let inline = currentInline
        if inline.hidden { return }

        var text = string.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
        let last = buffer.string.last
        if buffer.length == 0 || last == " " || last == "\u{2028}" {
            while text.hasPrefix(" ") { text.removeFirst() }
        }
        guard !text.isEmpty else { return }
        if inline.uppercase || inline.smallCaps { text = text.uppercased() }

        beginParagraphIfNeeded()
        buffer.append(NSAttributedString(string: text, attributes: attributes(inline)))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        guard let frame = frames.popLast() else { return }
        guard frame.isBlock else { return }

        let wasEmpty = frame.startLength == output.length + buffer.length
        flushParagraph()
        if wasEmpty && frame.name == "p" {
            // Leerer Absatz dient als Abstand
            pendingSpace = min(8, pendingSpace + lineUnit)
        }
        pendingSpace = max(pendingSpace, frame.marginBottom)
    }
}

// MARK: - Seitenumbruch

/// Ein gesetztes Kapitel: Text, Layout und die Zeichenbereiche der einzelnen Seiten.
final class ChapterLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    /// Gezeichnet wird im Hintergrund, angetippt auf dem Hauptthread: Zugriffe aufs Layout laufen nacheinander.
    let lock = NSRecursiveLock()
    private(set) var containers: [NSTextContainer] = []
    private(set) var pageRanges: [NSRange] = []

    var pageCount: Int { pageRanges.count }
    var length: Int { storage.length }
    var starts: [Int] { pageRanges.map { $0.location } }

    init(text: NSAttributedString, size: CGSize) {
        storage = NSTextStorage(attributedString: text)
        manager.usesFontLeading = false
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)

        let total = manager.numberOfGlyphs
        var laidOut = 0
        var guardCount = 0
        while laidOut < total && guardCount < 5000 {
            guardCount += 1
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            if glyphs.length == 0 {
                // Passt nichts mehr (z. B. zu großes Bild): abbrechen statt endlos Seiten anzulegen.
                manager.removeTextContainer(at: manager.textContainers.count - 1)
                break
            }
            containers.append(container)
            pageRanges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            laidOut = NSMaxRange(glyphs)
        }
        if containers.isEmpty {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            pageRanges.append(NSRange(location: 0, length: storage.length))
        }
    }

    func draw(page: Int, at origin: CGPoint) {
        guard page >= 0, page < containers.count else { return }
        lock.lock()
        defer { lock.unlock() }
        let glyphs = manager.glyphRange(for: containers[page])
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// Rechtecke, die ein Zeichenbereich auf einer Seite belegt (für Markierungen).
    func rects(for range: NSRange, page: Int) -> [CGRect] {
        guard page >= 0, page < containers.count else { return [] }
        let visible = NSIntersectionRange(range, pageRanges[page])
        guard visible.length > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let glyphs = manager.glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
        var result: [CGRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: containers[page]) { rect, _ in
            result.append(rect)
        }
        return result
    }

    func characterIndex(at point: CGPoint, page: Int) -> Int? {
        guard page >= 0, page < containers.count else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: point, in: containers[page], fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: containers[page])
        guard glyphRect.insetBy(dx: -12, dy: -8).contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard NSLocationInRange(index, pageRanges[page]) else { return nil }
        return index
    }

    func wordRange(at index: Int) -> NSRange? {
        let text = storage.string as NSString
        guard index >= 0, index < text.length else { return nil }
        let paragraph = text.paragraphRange(for: NSRange(location: index, length: 0))
        var found: NSRange?
        text.enumerateSubstrings(in: paragraph, options: .byWords) { _, range, _, stop in
            if NSLocationInRange(index, range) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    func sentenceRange(at index: Int) -> NSRange? {
        let text = storage.string as NSString
        guard index >= 0, index < text.length else { return nil }
        let paragraph = text.paragraphRange(for: NSRange(location: index, length: 0))
        var found: NSRange?
        text.enumerateSubstrings(in: paragraph, options: .bySentences) { _, range, _, stop in
            if NSLocationInRange(index, range) {
                found = range
                stop.pointee = true
            }
        }
        guard var result = found else { return nil }
        // Leerraum am Satzende nicht mitmarkieren
        while result.length > 0 {
            let last = text.character(at: NSMaxRange(result) - 1)
            guard let scalar = UnicodeScalar(last), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            result.length -= 1
        }
        return result.length > 0 ? result : nil
    }

    func string(in range: NSRange) -> String {
        let text = storage.string as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        return text.substring(with: safe)
    }
}

// MARK: - Buch

struct Pagination: Codable {
    var starts: [[Int]]
    var lengths: [Int]
}

/// Setzt Kapitel bei Bedarf, hält die zuletzt benutzten im Speicher und merkt sich
/// die Seitenaufteilung auf der Platte, damit das Buch beim nächsten Mal sofort offen ist.
final class BookEngine {
    static let version = "t2"

    let root: URL
    let files: [URL]

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lesen.engine", qos: .userInitiated)
    private var sheet: StyleSheet?
    private var cache: [Int: ChapterLayout] = [:]
    private var recent: [Int] = []
    private var generation = 0
    private var layout: PageLayout?
    private var theme: ReadingTheme = .paper

    init(root: URL, files: [URL]) {
        self.root = root
        self.files = files
    }

    func configure(layout: PageLayout, theme: ReadingTheme) {
        lock.lock()
        self.layout = layout
        self.theme = theme
        generation += 1
        cache.removeAll()
        recent.removeAll()
        lock.unlock()
    }

    private func styleSheet() -> StyleSheet {
        lock.lock()
        if let sheet {
            lock.unlock()
            return sheet
        }
        lock.unlock()

        var loaded = StyleSheet()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "css" {
                if let css = try? String(contentsOf: url, encoding: .utf8) {
                    loaded.add(css: css)
                }
            }
        }
        lock.lock()
        sheet = loaded
        lock.unlock()
        return loaded
    }

    private func build(chapter: Int, layout: PageLayout, theme: ReadingTheme) -> ChapterLayout {
        let config = TextConfig(
            font: layout.font,
            fontSize: CGFloat(layout.fontSize),
            lineHeight: CGFloat(layout.lineHeight),
            textColor: theme.textColor,
            contentSize: layout.contentSize
        )
        let text = ChapterBuilder.build(fileURL: files[chapter], config: config, sheet: styleSheet())
        return ChapterLayout(text: text, size: layout.contentSize)
    }

    private func store(_ built: ChapterLayout, chapter: Int, generation expected: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard expected == generation, cache[chapter] == nil else { return }
        cache[chapter] = built
        recent.removeAll { $0 == chapter }
        recent.append(chapter)
        while recent.count > 6 {
            let oldest = recent.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Liefert das gesetzte Kapitel. Ist es noch nicht im Speicher, wird es sofort gesetzt.
    func chapter(_ index: Int) -> ChapterLayout? {
        guard index >= 0, index < files.count else { return nil }
        lock.lock()
        let cached = cache[index]
        let currentLayout = layout
        let currentTheme = theme
        let currentGeneration = generation
        if cached != nil {
            recent.removeAll { $0 == index }
            recent.append(index)
        }
        lock.unlock()
        if let cached { return cached }
        guard let currentLayout else { return nil }
        if Thread.isMainThread {
            ReaderDiagnostics.shared.recordMainBuild()
        }
        let built = build(chapter: index, layout: currentLayout, theme: currentTheme)
        store(built, chapter: index, generation: currentGeneration)
        lock.lock()
        let resolved = cache[index] ?? built
        lock.unlock()
        return resolved
    }

    /// Setzt ein Kapitel im Hintergrund vor, damit der Kapitelwechsel nicht ruckelt.
    func prefetch(_ index: Int) {
        guard index >= 0, index < files.count else { return }
        lock.lock()
        let known = cache[index] != nil
        let currentLayout = layout
        let currentTheme = theme
        let currentGeneration = generation
        lock.unlock()
        guard !known, let currentLayout else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let built = self.build(chapter: index, layout: currentLayout, theme: currentTheme)
            self.store(built, chapter: index, generation: currentGeneration)
        }
    }

    // MARK: Seitenaufteilung des ganzen Buchs

    private var cacheURL: URL {
        root.appendingPathComponent("lesen-seiten.json")
    }

    private func readCache() -> [String: Pagination] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Pagination].self, from: data) else { return [:] }
        return decoded
    }

    func paginate(layout: PageLayout, theme: ReadingTheme, progress: @escaping (Double) -> Void) async -> Pagination? {
        let key = "\(BookEngine.version)|\(layout.cacheKey)"
        let count = files.count
        var stored = readCache()
        if let hit = stored[key], hit.starts.count == count, hit.lengths.count == count {
            return hit
        }

        let result: Pagination? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                var starts: [[Int]] = []
                var lengths: [Int] = []
                for chapter in 0..<count {
                    if Task.isCancelled { break }
                    autoreleasepool {
                        let built = self.build(chapter: chapter, layout: layout, theme: theme)
                        starts.append(built.starts)
                        lengths.append(built.length)
                    }
                    let fraction = Double(chapter + 1) / Double(max(1, count))
                    DispatchQueue.main.async { progress(fraction) }
                }
                continuation.resume(returning: starts.count == count ? Pagination(starts: starts, lengths: lengths) : nil)
            }
        }
        guard let result else { return nil }

        if stored.count >= 8 { stored.removeAll() }
        stored[key] = result
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return result
    }
}
