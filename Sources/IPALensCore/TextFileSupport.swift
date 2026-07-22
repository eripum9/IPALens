import Foundation

enum TextFileSupport {
    private static let syntaxByExtension: [String: String] = [
        // Apple and native development
        "swift": "Swift", "metal": "Metal", "m": "Objective-C", "mm": "Objective-C++",
        "h": "C / Objective-C Header", "hh": "C++ Header", "hpp": "C++ Header", "hxx": "C++ Header",
        "c": "C", "cc": "C++", "cpp": "C++", "cxx": "C++", "pch": "C / Objective-C Header",
        "pbxproj": "Xcode Project", "xcconfig": "Xcode Configuration", "xcscheme": "XML",
        "xcworkspacedata": "XML", "modulemap": "Clang Module Map", "defs": "Definitions",

        // Web and Node.js
        "html": "HTML", "htm": "HTML", "xhtml": "HTML", "css": "CSS", "scss": "SCSS",
        "sass": "Sass", "less": "Less", "styl": "Stylus", "js": "JavaScript", "mjs": "JavaScript",
        "cjs": "JavaScript", "jsx": "JavaScript JSX", "ts": "TypeScript", "tsx": "TypeScript JSX",
        "vue": "Vue", "svelte": "Svelte", "astro": "Astro", "ejs": "EJS", "hbs": "Handlebars",
        "handlebars": "Handlebars", "mustache": "Mustache", "pug": "Pug", "jade": "Pug",
        "twig": "Twig", "webmanifest": "JSON", "map": "JSON",

        // General programming languages
        "py": "Python", "pyw": "Python", "pyi": "Python", "java": "Java", "kt": "Kotlin",
        "kts": "Kotlin", "scala": "Scala", "sc": "Scala", "groovy": "Groovy", "gradle": "Gradle",
        "cs": "C#", "fs": "F#", "fsx": "F#", "vb": "Visual Basic", "go": "Go", "rs": "Rust",
        "rb": "Ruby", "rake": "Ruby", "gemspec": "Ruby", "podspec": "Ruby", "php": "PHP",
        "php3": "PHP", "php4": "PHP", "php5": "PHP", "phtml": "PHP", "pl": "Perl", "pm": "Perl",
        "t": "Perl", "lua": "Lua", "dart": "Dart", "r": "R", "jl": "Julia", "ex": "Elixir",
        "exs": "Elixir", "erl": "Erlang", "hrl": "Erlang", "clj": "Clojure", "cljs": "Clojure",
        "cljc": "Clojure", "edn": "Clojure", "hs": "Haskell", "lhs": "Haskell", "ml": "OCaml",
        "mli": "OCaml", "elm": "Elm", "sol": "Solidity", "move": "Move", "zig": "Zig",
        "nim": "Nim", "cr": "Crystal", "coffee": "CoffeeScript", "tcl": "Tcl", "v": "V",
        "pas": "Pascal", "pp": "Pascal", "f": "Fortran", "f90": "Fortran", "f95": "Fortran",
        "f03": "Fortran", "f08": "Fortran", "asm": "Assembly", "s": "Assembly",

        // Shell, build, automation, and configuration
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "fish": "Fish", "ps1": "PowerShell",
        "bat": "Batch", "cmd": "Batch", "mk": "Makefile", "cmake": "CMake", "ninja": "Ninja",
        "bazel": "Bazel", "bzl": "Bazel", "buck": "Buck", "dockerfile": "Dockerfile",
        "containerfile": "Containerfile", "toml": "TOML", "ini": "INI", "cfg": "Configuration",
        "conf": "Configuration", "config": "Configuration", "properties": "Properties", "env": "Environment",
        "editorconfig": "EditorConfig", "gitignore": "Git Ignore", "gitattributes": "Git Attributes",
        "npmrc": "npm Configuration", "yarnrc": "Yarn Configuration", "lock": "Lock File",

        // Structured data, query, markup, and documentation
        "json": "JSON", "json5": "JSON5", "jsonl": "JSON Lines", "ndjson": "JSON Lines",
        "geojson": "GeoJSON", "ipynb": "Jupyter Notebook", "xml": "XML", "xsd": "XML Schema",
        "xsl": "XSLT", "xslt": "XSLT", "svg": "SVG", "yaml": "YAML", "yml": "YAML",
        "sql": "SQL", "graphql": "GraphQL", "gql": "GraphQL", "proto": "Protocol Buffers",
        "thrift": "Thrift", "csv": "CSV", "tsv": "TSV", "txt": "Plain Text", "text": "Plain Text",
        "log": "Log", "md": "Markdown", "markdown": "Markdown", "mdx": "MDX", "rst": "reStructuredText",
        "adoc": "AsciiDoc", "asciidoc": "AsciiDoc", "tex": "TeX", "bib": "BibTeX",
        "stringsdict": "Property List", "entitlements": "Property List", "storyboard": "XML", "xib": "XML",
        "plist": "Property List", "xcprivacy": "Property List"
    ]

    private static let syntaxByFileName: [String: String] = [
        "dockerfile": "Dockerfile", "containerfile": "Containerfile", "makefile": "Makefile",
        "gnumakefile": "Makefile", "cmakelists.txt": "CMake", "gemfile": "Ruby", "rakefile": "Ruby",
        "podfile": "Ruby", "cartfile": "Swift", "fastfile": "Ruby", "deliverfile": "Ruby",
        "appfile": "Ruby", "dangerfile": "Ruby", "brewfile": "Ruby", "vagrantfile": "Ruby",
        "procfile": "Configuration", "package.resolved": "JSON", "package.swift": "Swift",
        "license": "Plain Text", "copying": "Plain Text", "readme": "Markdown", "changelog": "Markdown",
        ".gitignore": "Git Ignore", ".gitattributes": "Git Attributes", ".gitmodules": "Git Configuration",
        ".editorconfig": "EditorConfig", ".env": "Environment", ".npmrc": "npm Configuration",
        ".yarnrc": "Yarn Configuration", ".babelrc": "JSON", ".eslintrc": "JSON",
        ".prettierrc": "JSON", ".bashrc": "Shell", ".zshrc": "Shell", ".profile": "Shell"
    ]

    static func isDeclaredText(name: String) -> Bool {
        syntax(name: name, contents: nil) != nil
    }

    static func syntax(name: String, contents: String?) -> String? {
        let lowercasedName = name.lowercased()
        if let syntax = syntaxByFileName[lowercasedName] { return syntax }
        let fileExtension = (lowercasedName as NSString).pathExtension
        if let syntax = syntaxByExtension[fileExtension] { return syntax }
        guard let firstLine = contents?.split(whereSeparator: \Character.isNewline).first,
              firstLine.hasPrefix("#!") else { return nil }
        let shebang = firstLine.lowercased()
        if shebang.contains("node") || shebang.contains("deno") || shebang.contains("bun") { return "JavaScript" }
        if shebang.contains("python") { return "Python" }
        if shebang.contains("ruby") { return "Ruby" }
        if shebang.contains("perl") { return "Perl" }
        if shebang.contains("php") { return "PHP" }
        if shebang.contains("swift") { return "Swift" }
        if shebang.contains("fish") { return "Fish" }
        if shebang.contains("bash") || shebang.contains("zsh") || shebang.contains("/sh") { return "Shell" }
        return "Executable Text"
    }

    static func decode(_ data: Data, allowLegacyEncoding: Bool) -> String? {
        if data.isEmpty { return "" }

        let decoded: String?
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        } else if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            decoded = String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else if let encoding = likelyUTF16Encoding(data) {
            decoded = String(data: data, encoding: encoding)
        } else if allowLegacyEncoding, isPlausibleSingleByteText(data) {
            decoded = String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        } else {
            decoded = nil
        }

        guard let decoded, isReadableText(decoded) else { return nil }
        return decoded.first?.unicodeScalars.first?.value == 0xFEFF
            ? String(decoded.dropFirst())
            : decoded
    }

    private static func likelyUTF16Encoding(_ data: Data) -> String.Encoding? {
        let bytes = [UInt8](data.prefix(4_096))
        guard bytes.count >= 4, bytes.count.isMultiple(of: 2) else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            if bytes[index] == 0 { evenZeros += 1 }
            if bytes[index + 1] == 0 { oddZeros += 1 }
        }
        let pairs = bytes.count / 2
        if oddZeros * 2 > pairs, evenZeros * 10 < pairs { return .utf16LittleEndian }
        if evenZeros * 2 > pairs, oddZeros * 10 < pairs { return .utf16BigEndian }
        return nil
    }

    private static func isPlausibleSingleByteText(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64 * 1_024))
        guard !bytes.contains(0) else { return false }
        let controls = bytes.filter { byte in
            (byte < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(byte)) || byte == 0x7F
        }.count
        return controls == 0 || (bytes.count >= 100 && controls * 100 <= bytes.count)
    }

    private static func isReadableText(_ text: String) -> Bool {
        var scalarCount = 0
        var controlCount = 0
        for scalar in text.unicodeScalars.prefix(64 * 1_024) {
            scalarCount += 1
            let value = scalar.value
            if (value < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(value)) || value == 0x7F {
                controlCount += 1
            }
        }
        return controlCount == 0 || (scalarCount >= 100 && controlCount * 100 <= scalarCount)
    }
}
