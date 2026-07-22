import AppKit
import SwiftUI

struct SourceCodePreviewView: NSViewRepresentable {
    let text: String
    let syntax: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = XcodePalette.background

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = XcodePalette.background
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.update(text: text, syntax: syntax)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(text: text, syntax: syntax)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancel()
        (scrollView.documentView as? NSTextView)?.textStorage?.setAttributedString(.init())
    }

    final class Coordinator: @unchecked Sendable {
        weak var textView: NSTextView?
        private var renderedText: String?
        private var renderedSyntax: String?
        private var generation = UUID()
        private var highlightingTask: Task<Void, Never>?

        @MainActor
        func update(text: String, syntax: String) {
            guard renderedText != text || renderedSyntax != syntax else { return }
            renderedText = text
            renderedSyntax = syntax
            generation = UUID()
            highlightingTask?.cancel()

            guard let textView, let storage = textView.textStorage else { return }
            storage.setAttributedString(NSAttributedString(
                string: text,
                attributes: XcodePalette.baseAttributes
            ))
            textView.backgroundColor = XcodePalette.background
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)

            let expectedGeneration = generation
            let tokenTask = Task.detached(priority: .utility) {
                SourceSyntaxHighlighter.highlightSpans(in: text, syntax: syntax)
            }
            highlightingTask = Task { @MainActor [weak self] in
                let spans = await tokenTask.value
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      let storage = self.textView?.textStorage else { return }
                storage.beginEditing()
                for span in spans where NSMaxRange(span.range) <= storage.length {
                    storage.addAttribute(
                        .foregroundColor,
                        value: XcodePalette.color(for: span.kind),
                        range: span.range
                    )
                }
                storage.endEditing()
            }
        }

        @MainActor
        func cancel() {
            generation = UUID()
            highlightingTask?.cancel()
            highlightingTask = nil
        }
    }
}

private enum HighlightKind: Sendable {
    case keyword
    case type
    case function
    case property
    case number
    case string
    case comment
}

private struct HighlightSpan: Sendable {
    let range: NSRange
    let kind: HighlightKind
}

private enum SourceSyntaxHighlighter {
    // Keeping the colored region bounded prevents a multi-megabyte source file from
    // monopolizing a CPU core. The complete file remains visible in the base editor style.
    private static let maximumHighlightedUTF16Length = 1_500_000

    static func highlightSpans(in text: String, syntax: String) -> [HighlightSpan] {
        guard syntax != "Plain Text", syntax != "CSV", syntax != "TSV", syntax != "Log" else { return [] }
        let source = text as NSString
        let length = min(source.length, maximumHighlightedUTF16Length)
        guard length > 0 else { return [] }

        let protected = lexicalSpans(in: source, length: length, syntax: syntax)
        var result: [HighlightSpan] = []
        appendMatches(
            pattern: #"\b(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#,
            kind: .number,
            source: source,
            length: length,
            protected: protected,
            to: &result
        )

        if isMarkup(syntax) {
            appendMatches(
                pattern: #"<\/?\s*([A-Za-z][A-Za-z0-9:_-]*)"#,
                captureGroup: 1,
                kind: .type,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
            appendMatches(
                pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?=\s*=)"#,
                captureGroup: 1,
                kind: .property,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        } else if syntax == "CSS" || syntax == "SCSS" || syntax == "Sass" || syntax == "Less" {
            appendMatches(
                pattern: #"(?m)^\s*([-A-Za-z_][-A-Za-z0-9_]*)(?=\s*:)"#,
                captureGroup: 1,
                kind: .property,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        } else if isKeyValueSyntax(syntax) {
            appendMatches(
                pattern: #"(?m)^\s*[-]?\s*([A-Za-z_][A-Za-z0-9_.-]*)(?=\s*[:=])"#,
                captureGroup: 1,
                kind: .property,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        }

        if syntax == "Markdown" || syntax == "MDX" || syntax == "AsciiDoc" || syntax == "reStructuredText" {
            appendMatches(
                pattern: #"(?m)^\s*(?:#{1,6}|={1,6})\s+.+$"#,
                kind: .keyword,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        }

        if supportsIdentifiers(syntax) {
            appendMatches(
                pattern: #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*(?=\()"#,
                captureGroup: 1,
                kind: .function,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
            appendMatches(
                pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#,
                kind: .type,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        }

        let keywords = keywords(for: syntax)
        if !keywords.isEmpty {
            let pattern = #"\b(?:"# + keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
            appendMatches(
                pattern: pattern,
                kind: .keyword,
                source: source,
                length: length,
                protected: protected,
                to: &result
            )
        }

        result.append(contentsOf: protected)
        return result
    }

    private static func lexicalSpans(in source: NSString, length: Int, syntax: String) -> [HighlightSpan] {
        let rules = lexicalRules(for: syntax)
        guard !rules.lineComments.isEmpty || !rules.blockComments.isEmpty || !rules.quotes.isEmpty else { return [] }
        var spans: [HighlightSpan] = []
        var index = 0

        while index < length {
            if let block = rules.blockComments.first(where: { hasPrefix($0.0, source: source, at: index, length: length) }) {
                let end = endOfDelimitedToken(
                    source: source,
                    start: index,
                    opener: block.0,
                    closer: block.1,
                    length: length,
                    honorsEscapes: false
                )
                spans.append(.init(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end
                continue
            }
            if let marker = rules.lineComments.first(where: { hasPrefix($0, source: source, at: index, length: length) }) {
                var end = index + marker.utf16.count
                while end < length, source.character(at: end) != 0x0A, source.character(at: end) != 0x0D { end += 1 }
                spans.append(.init(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end
                continue
            }
            if let quote = rules.quotes.first(where: { hasPrefix($0, source: source, at: index, length: length) }) {
                let end = endOfDelimitedToken(
                    source: source,
                    start: index,
                    opener: quote,
                    closer: quote,
                    length: length,
                    honorsEscapes: true
                )
                let tokenRange = NSRange(location: index, length: end - index)
                let kind = isDataKey(tokenRange, source: source, length: length, syntax: syntax) ? HighlightKind.property : .string
                spans.append(.init(range: tokenRange, kind: kind))
                index = end
                continue
            }
            index += 1
        }
        return spans
    }

    private static func endOfDelimitedToken(
        source: NSString,
        start: Int,
        opener: String,
        closer: String,
        length: Int,
        honorsEscapes: Bool
    ) -> Int {
        var index = start + opener.utf16.count
        while index < length {
            if honorsEscapes, source.character(at: index) == 0x5C {
                index = min(length, index + 2)
                continue
            }
            if hasPrefix(closer, source: source, at: index, length: length) {
                return min(length, index + closer.utf16.count)
            }
            if opener.utf16.count == 1,
               source.character(at: index) == 0x0A || source.character(at: index) == 0x0D {
                return index
            }
            index += 1
        }
        return length
    }

    private static func hasPrefix(_ value: String, source: NSString, at index: Int, length: Int) -> Bool {
        let tokenLength = value.utf16.count
        guard index + tokenLength <= length else { return false }
        return source.substring(with: NSRange(location: index, length: tokenLength)) == value
    }

    private static func isDataKey(_ range: NSRange, source: NSString, length: Int, syntax: String) -> Bool {
        guard ["JSON", "JSON5", "JSON Lines", "GeoJSON", "Jupyter Notebook"].contains(syntax) else { return false }
        var index = NSMaxRange(range)
        while index < length,
              let scalar = UnicodeScalar(source.character(at: index)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            index += 1
        }
        return index < length && source.character(at: index) == 0x3A
    }

    private static func appendMatches(
        pattern: String,
        captureGroup: Int = 0,
        kind: HighlightKind,
        source: NSString,
        length: Int,
        protected: [HighlightSpan],
        to result: inout [HighlightSpan]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: source as String, range: NSRange(location: 0, length: length)) {
            let range = match.range(at: captureGroup)
            guard range.location != NSNotFound, !intersectsProtected(range, protected: protected) else { continue }
            result.append(.init(range: range, kind: kind))
        }
    }

    private static func intersectsProtected(_ range: NSRange, protected: [HighlightSpan]) -> Bool {
        var lower = 0
        var upper = protected.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(protected[middle].range) <= range.location { lower = middle + 1 } else { upper = middle }
        }
        return lower < protected.count && NSIntersectionRange(range, protected[lower].range).length > 0
    }

    private static func keywords(for syntax: String) -> [String] {
        switch syntax {
        case "Swift", "Metal":
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "let", "nil", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "yield"]
        case "JavaScript", "JavaScript JSX", "TypeScript", "TypeScript JSX", "Vue", "Svelte", "Astro", "EJS":
            return ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "package", "private", "protected", "public", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case "Python":
            return ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
        case "Java", "Kotlin", "Scala", "Groovy", "Gradle", "C#", "Dart":
            return ["abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class", "const", "continue", "default", "delegate", "do", "else", "enum", "extends", "false", "final", "finally", "for", "foreach", "fun", "get", "if", "implements", "import", "in", "interface", "internal", "is", "namespace", "new", "null", "object", "open", "operator", "out", "override", "package", "private", "protected", "public", "record", "return", "sealed", "set", "static", "struct", "super", "switch", "this", "throw", "throws", "trait", "true", "try", "typealias", "typeof", "using", "val", "var", "virtual", "void", "when", "while", "yield"]
        case "C", "C++", "Objective-C", "Objective-C++", "C / Objective-C Header", "C++ Header", "Assembly":
            return ["alignas", "alignof", "asm", "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "if", "inline", "int", "long", "namespace", "new", "nil", "noexcept", "nullptr", "private", "protected", "public", "register", "return", "self", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "virtual", "void", "volatile", "while"]
        case "Go":
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
        case "Rust":
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case "Ruby":
            return ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case "PHP":
            return ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or", "private", "protected", "public", "readonly", "require", "return", "static", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield"]
        case "Shell", "Fish", "PowerShell", "Batch":
            return ["alias", "break", "case", "continue", "do", "done", "elif", "else", "end", "esac", "export", "false", "fi", "for", "foreach", "function", "if", "in", "local", "return", "set", "switch", "then", "true", "until", "while"]
        case "SQL":
            return ["add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check", "column", "commit", "constraint", "create", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "false", "foreign", "from", "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "primary", "references", "right", "rollback", "select", "set", "table", "then", "true", "union", "unique", "update", "values", "view", "when", "where", "with"]
        case "Lua":
            return ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]
        default:
            return []
        }
    }

    private static func lexicalRules(for syntax: String) -> (
        lineComments: [String],
        blockComments: [(String, String)],
        quotes: [String]
    ) {
        if syntax == "Plain Text" || syntax == "CSV" || syntax == "TSV" || syntax == "Log" {
            return ([], [], [])
        }
        if isMarkup(syntax) {
            return ([], [("<!--", "-->")], ["\"", "'"])
        }
        if syntax == "Python" {
            return (["#"], [], ["\"\"\"", "'''", "\"", "'"])
        }
        if ["Shell", "Fish", "Ruby", "Perl", "R", "Julia", "YAML", "TOML", "Dockerfile", "Containerfile", "Makefile", "CMake", "Configuration", "Environment", "Properties", "EditorConfig", "Git Ignore", "Git Attributes", "Git Configuration", "npm Configuration", "Yarn Configuration"].contains(syntax) {
            return (["#"], [], ["\"", "'", "`"])
        }
        if syntax == "SQL" || syntax == "Lua" {
            return (["--"], [("/*", "*/")], ["\"", "'"])
        }
        if syntax == "INI" {
            return ([";", "#"], [], ["\"", "'"])
        }
        if ["JSON", "JSON5", "JSON Lines", "GeoJSON", "Jupyter Notebook"].contains(syntax) {
            let comments = syntax == "JSON5" ? ["//"] : []
            let blocks = syntax == "JSON5" ? [("/*", "*/")] : []
            return (comments, blocks, ["\"", "'"])
        }
        if syntax == "Markdown" || syntax == "MDX" || syntax == "AsciiDoc" || syntax == "reStructuredText" {
            return ([], [("<!--", "-->")], ["```", "`", "\""])
        }
        return (["//"], [("/*", "*/")], ["\"\"\"", "'''", "\"", "'", "`"])
    }

    private static func isMarkup(_ syntax: String) -> Bool {
        ["HTML", "XML", "XML Schema", "XSLT", "SVG", "Vue", "Svelte", "Astro", "Handlebars", "Mustache", "Twig", "XML Property List", "Property List"].contains(syntax)
    }

    private static func isKeyValueSyntax(_ syntax: String) -> Bool {
        ["YAML", "TOML", "INI", "Configuration", "Environment", "Properties", "EditorConfig", "Git Configuration", "npm Configuration", "Yarn Configuration"].contains(syntax)
    }

    private static func supportsIdentifiers(_ syntax: String) -> Bool {
        !isMarkup(syntax)
            && !isKeyValueSyntax(syntax)
            && !["JSON", "JSON5", "JSON Lines", "GeoJSON", "Jupyter Notebook", "Markdown", "MDX", "AsciiDoc", "reStructuredText", "CSV", "TSV"].contains(syntax)
    }
}

private enum XcodePalette {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x1F1F24)
    static let foreground = dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let keyword = dynamic(light: 0x9B2393, dark: 0xFF7AB2)
    static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
    static let function = dynamic(light: 0x326D74, dark: 0x67B7A4)
    static let property = dynamic(light: 0x703DAA, dark: 0xB281EB)
    static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.defaultTabInterval = 32
        return [
            .font: NSFont(name: "SFMono-Regular", size: 12.5)
                ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: foreground,
            .backgroundColor: background,
            .paragraphStyle: paragraph
        ]
    }

    static func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .function: function
        case .property: property
        case .number: number
        case .string: string
        case .comment: comment
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color(useDark ? dark : light)
        }
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
