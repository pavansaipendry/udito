import SwiftUI

/// Lightweight syntax highlighting for code the guest pastes into Live
/// Transcript chat. No grammar dependency — a single-pass tokenizer
/// (comments, strings, numbers, identifiers) plus per-language keyword sets
/// covers pasted snippets well, and unknown languages degrade to a still-
/// pleasant generic coloring. Palette follows Xcode's default dark theme;
/// the code block always renders on a dark background.
enum CodeHighlighter {

    // MARK: - Palette (Xcode default dark)

    private static let plainColor = Color(red: 0.92, green: 0.93, blue: 0.96)
    private static let keywordColor = Color(red: 0.99, green: 0.37, blue: 0.64)   // #FC5FA3
    private static let stringColor = Color(red: 0.99, green: 0.42, blue: 0.37)    // #FC6A5D
    private static let numberColor = Color(red: 0.82, green: 0.75, blue: 0.41)    // #D0BF69
    private static let commentColor = Color(red: 0.42, green: 0.47, blue: 0.53)   // #6C7986
    private static let typeColor = Color(red: 0.36, green: 0.85, blue: 1.0)       // #5DD8FF
    private static let functionColor = Color(red: 0.70, green: 0.55, blue: 0.98)  // #B38CF9
    private static let attributeColor = Color(red: 0.99, green: 0.56, blue: 0.25) // #FD8F3F

    // MARK: - Language table

    private struct Spec {
        var keywords: Set<String>
        var literals: Set<String> = ["true", "false", "null", "nil", "None", "True", "False", "undefined", "NULL"]
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var stringDelimiters: Set<Character> = ["\"", "'"]
        var allowsTripleQuotes = false
    }

    private static let jsKeywords: Set<String> = [
        "function", "const", "let", "var", "if", "else", "return", "for", "while", "do",
        "switch", "case", "default", "break", "continue", "new", "delete", "typeof",
        "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export",
        "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "void",
        "static", "get", "set", "interface", "type", "enum", "implements", "declare",
        "readonly", "namespace", "public", "private", "protected", "abstract", "satisfies",
        "keyof", "infer", "never", "unknown", "any", "string", "number", "boolean", "object",
    ]

    private static let cFamilyKeywords: Set<String> = [
        "int", "long", "short", "char", "double", "float", "void", "unsigned", "signed",
        "struct", "union", "enum", "typedef", "sizeof", "static", "extern", "const",
        "volatile", "goto", "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "class", "public", "private", "protected", "virtual",
        "override", "final", "abstract", "interface", "extends", "implements", "new",
        "delete", "this", "super", "package", "import", "namespace", "using", "template",
        "typename", "try", "catch", "finally", "throw", "throws", "synchronized",
        "instanceof", "var", "val", "fun", "when", "object", "data", "sealed", "companion",
        "init", "lateinit", "auto", "constexpr", "nullptr", "bool", "string", "boolean",
    ]

    private static let specs: [String: Spec] = [
        "swift": Spec(keywords: [
            "func", "let", "var", "if", "else", "guard", "return", "for", "while", "repeat",
            "switch", "case", "default", "break", "continue", "fallthrough", "import",
            "struct", "class", "enum", "protocol", "extension", "init", "deinit", "self",
            "super", "throws", "throw", "try", "catch", "do", "as", "is", "in", "where",
            "defer", "static", "private", "public", "internal", "fileprivate", "open",
            "final", "lazy", "weak", "unowned", "mutating", "override", "required",
            "convenience", "typealias", "associatedtype", "some", "any", "await", "async",
            "actor", "nonisolated", "inout", "willSet", "didSet", "get", "set", "subscript",
            "operator", "indirect",
        ], allowsTripleQuotes: true),
        "javascript": Spec(keywords: jsKeywords),
        "typescript": Spec(keywords: jsKeywords),
        "python": Spec(keywords: [
            "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
            "and", "or", "is", "import", "from", "as", "with", "lambda", "yield", "global",
            "nonlocal", "try", "except", "finally", "raise", "pass", "break", "continue",
            "del", "assert", "async", "await", "match", "case", "self", "print",
        ], lineComments: ["#"], blockComment: nil, allowsTripleQuotes: true),
        "c": Spec(keywords: cFamilyKeywords),
        "cpp": Spec(keywords: cFamilyKeywords),
        "java": Spec(keywords: cFamilyKeywords),
        "csharp": Spec(keywords: cFamilyKeywords),
        "kotlin": Spec(keywords: cFamilyKeywords),
        "go": Spec(keywords: [
            "package", "import", "func", "var", "const", "type", "struct", "interface",
            "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case",
            "default", "break", "continue", "return", "select", "fallthrough", "goto",
            "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover",
            "iota", "error", "string", "int", "int64", "float64", "bool", "byte", "rune",
        ], stringDelimiters: ["\"", "'", "`"]),
        "rust": Spec(keywords: [
            "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for",
            "while", "loop", "if", "else", "match", "return", "use", "mod", "pub", "crate",
            "self", "super", "where", "async", "await", "move", "ref", "dyn", "unsafe",
            "extern", "type", "as", "in", "break", "continue",
        ]),
        "ruby": Spec(keywords: [
            "def", "end", "class", "module", "if", "elsif", "else", "unless", "while",
            "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure",
            "raise", "require", "require_relative", "attr_accessor", "attr_reader", "puts",
            "print", "new", "self", "and", "or", "not", "then", "case", "when", "lambda",
            "proc",
        ], lineComments: ["#"], blockComment: ("=begin", "=end")),
        "php": Spec(keywords: [
            "function", "echo", "print", "if", "else", "elseif", "for", "foreach", "while",
            "do", "switch", "case", "default", "break", "continue", "return", "class",
            "public", "private", "protected", "static", "new", "extends", "implements",
            "namespace", "use", "require", "include", "try", "catch", "finally", "throw",
            "as", "array",
        ], lineComments: ["//", "#"]),
        "shell": Spec(keywords: [
            "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
            "case", "esac", "function", "echo", "printf", "export", "local", "return",
            "exit", "source", "set", "read", "cd", "sudo", "grep", "sed", "awk", "cat",
        ], lineComments: ["#"], blockComment: nil),
        "sql": Spec(keywords: sqlKeywords, lineComments: ["--"]),
        "css": Spec(keywords: ["important", "media", "screen", "hover", "focus", "active", "root"],
                    lineComments: []),
        "html": Spec(keywords: [
            "html", "head", "body", "div", "span", "script", "style", "link", "meta",
            "title", "a", "p", "img", "ul", "ol", "li", "table", "tr", "td", "th", "input",
            "button", "form", "section", "header", "footer", "nav", "main", "h1", "h2",
            "h3", "br", "hr",
        ], lineComments: [], blockComment: ("<!--", "-->")),
        "json": Spec(keywords: [], lineComments: [], blockComment: nil),
        "yaml": Spec(keywords: [], lineComments: ["#"], blockComment: nil),
    ]

    private static let sqlKeywords: Set<String> = {
        let upper: Set<String> = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "INSERT", "INTO",
            "VALUES", "UPDATE", "SET", "DELETE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
            "ON", "GROUP", "BY", "ORDER", "LIMIT", "OFFSET", "HAVING", "AS", "DISTINCT",
            "CREATE", "TABLE", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "INDEX", "DROP",
            "ALTER", "ADD", "COLUMN", "UNION", "ALL", "EXISTS", "IN", "LIKE", "BETWEEN",
            "IS", "CASE", "WHEN", "THEN", "ELSE", "END", "COUNT", "SUM", "AVG", "MIN", "MAX",
        ]
        return upper.union(Set(upper.map { $0.lowercased() }))
    }()

    /// Fallback for unknown languages: a superset that colors most snippets
    /// acceptably.
    private static let genericSpec = Spec(
        keywords: jsKeywords
            .union(cFamilyKeywords)
            .union(specs["swift"]!.keywords)
            .union(specs["python"]!.keywords),
        lineComments: ["//", "#"],
        allowsTripleQuotes: true
    )

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "c#": "csharp", "cs": "csharp",
        "objc": "c", "objective-c": "c", "h": "c", "m": "c",
        "sh": "shell", "bash": "shell", "zsh": "shell",
        "yml": "yaml",
        "golang": "go",
        "rb": "ruby",
        "kt": "kotlin",
        "htm": "html", "xml": "html", "svg": "html",
    ]

    private static func spec(for language: String?) -> Spec {
        guard let language = language?.lowercased(), !language.isEmpty else { return genericSpec }
        let canonical = aliases[language] ?? language
        return specs[canonical] ?? genericSpec
    }

    /// Human label for the block header ("Swift", "C++", plain "Code" when
    /// unknown).
    static func displayName(for language: String?) -> String {
        guard let language = language?.lowercased(), !language.isEmpty else { return "Code" }
        let canonical = aliases[language] ?? language
        let names: [String: String] = [
            "javascript": "JavaScript", "typescript": "TypeScript", "cpp": "C++",
            "csharp": "C#", "php": "PHP", "css": "CSS", "html": "HTML", "json": "JSON",
            "yaml": "YAML", "sql": "SQL", "c": "C",
        ]
        if let pretty = names[canonical] { return pretty }
        return canonical.prefix(1).uppercased() + canonical.dropFirst()
    }

    // MARK: - Highlighting

    /// Colors only — the view applies the monospaced font, so runs inherit it.
    static func highlight(_ code: String, language: String?) -> AttributedString {
        let spec = spec(for: language)
        let chars = Array(code)
        var output = AttributedString()
        var plainRun = ""

        func flushPlain() {
            if !plainRun.isEmpty {
                output += colored(plainRun, plainColor)
                plainRun = ""
            }
        }
        func emit(_ text: String, _ color: Color) {
            flushPlain()
            output += colored(text, color)
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]

            if let opener = spec.lineComments.first(where: { matches(chars, at: i, token: $0) }) {
                var j = i + opener.count
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), commentColor)
                i = j
                continue
            }

            if let block = spec.blockComment, matches(chars, at: i, token: block.open) {
                var j = i + block.open.count
                while j < chars.count, !matches(chars, at: j, token: block.close) { j += 1 }
                if j < chars.count { j += block.close.count }
                emit(String(chars[i..<j]), commentColor)
                i = j
                continue
            }

            if spec.stringDelimiters.contains(c) {
                let end = consumeString(chars, from: i, delimiter: c, triple: spec.allowsTripleQuotes)
                emit(String(chars[i..<end]), stringColor)
                i = end
                continue
            }

            if c.isNumber {
                var j = i + 1
                while j < chars.count,
                      chars[j].isHexDigit || chars[j] == "." || chars[j] == "_"
                        || chars[j] == "x" || chars[j] == "o" || chars[j] == "b" {
                    j += 1
                }
                emit(String(chars[i..<j]), numberColor)
                i = j
                continue
            }

            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if spec.keywords.contains(word) || spec.literals.contains(word) {
                    emit(word, keywordColor)
                } else if word.first?.isUppercase == true {
                    emit(word, typeColor)
                } else {
                    var k = j
                    while k < chars.count, chars[k] == " " { k += 1 }
                    if k < chars.count, chars[k] == "(" {
                        emit(word, functionColor)
                    } else {
                        plainRun += word
                    }
                }
                i = j
                continue
            }

            // @Attribute, #directive, $variable — anything not already eaten
            // as a comment above.
            if c == "@" || c == "#" || c == "$", i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), attributeColor)
                i = j
                continue
            }

            plainRun += String(c)
            i += 1
        }
        flushPlain()
        return output
    }

    private static func colored(_ text: String, _ color: Color) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = color
        return piece
    }

    private static func matches(_ chars: [Character], at index: Int, token: String) -> Bool {
        let t = Array(token)
        guard index + t.count <= chars.count else { return false }
        for offset in 0..<t.count where chars[index + offset] != t[offset] { return false }
        return true
    }

    /// Returns the index just past the closing delimiter. Single-line strings
    /// stop at a newline so an unterminated quote can't swallow the rest of
    /// the snippet; triple-quoted and backtick strings may span lines.
    private static func consumeString(_ chars: [Character], from start: Int, delimiter: Character, triple: Bool) -> Int {
        var i = start
        let isTriple = triple && matches(chars, at: i, token: String(repeating: String(delimiter), count: 3))
        let multiline = isTriple || delimiter == "`"
        i += isTriple ? 3 : 1
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                i += 2
                continue
            }
            if !multiline, chars[i] == "\n" { return i }
            if chars[i] == delimiter {
                if isTriple {
                    if matches(chars, at: i, token: String(repeating: String(delimiter), count: 3)) {
                        return i + 3
                    }
                } else {
                    return i + 1
                }
            }
            i += 1
        }
        return chars.count
    }

    // MARK: - Language detection

    /// Best-effort guess for unlabeled pastes; nil when nothing scores
    /// convincingly (the block then renders with generic coloring).
    static func detectLanguage(of code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return "json"
            }
        }

        // (language, [(pattern, weight)]): a pattern scores its weight once if
        // present anywhere. Highest total ≥ 3 wins; ties go to the earlier row.
        let rules: [(String, [(String, Int)])] = [
            ("php", [("<\\?php", 5), ("\\$\\w+\\s*=", 2), ("->\\w+\\(", 1)]),
            ("html", [("(?i)<!doctype\\s+html", 5), ("(?i)</?(div|span|html|body|head|p|a|ul|li|table|script|style|section|nav)\\b", 3), ("(?i)<\\w+[^>]*>", 1)]),
            ("shell", [("(?m)^#!.*\\b(bash|sh|zsh)\\b", 5), ("(?m)^\\s*(fi|done|esac)\\b", 3), ("\\becho\\s", 2), ("\\$\\{?\\w+", 1)]),
            ("sql", [("(?is)\\bselect\\b.*\\bfrom\\b", 4), ("(?i)\\b(insert\\s+into|update\\s+\\w+\\s+set|create\\s+table|delete\\s+from)\\b", 4), ("(?i)\\bwhere\\b", 1)]),
            ("swift", [("\\bfunc\\s+\\w+", 2), ("\\bguard\\s", 3), ("\\b(let|var)\\s+\\w+\\s*[:=]", 1), ("\\bimport\\s+(Foundation|SwiftUI|UIKit|AppKit|Combine)\\b", 4), ("->\\s*\\w", 1)]),
            ("rust", [("\\bfn\\s+\\w+", 3), ("\\blet\\s+mut\\b", 3), ("println!", 3), ("\\bimpl\\s", 2)]),
            ("go", [("\\bpackage\\s+\\w+", 3), ("\\bfunc\\s+\\w+\\(", 2), (":=", 2), ("\\bfmt\\.", 2)]),
            ("kotlin", [("\\bfun\\s+\\w+\\(", 3), ("\\bval\\s+\\w+", 2), ("\\bcompanion\\s+object\\b", 3)]),
            ("python", [("(?m)^\\s*def\\s+\\w+\\s*\\(", 3), ("\\belif\\b", 3), ("\\bself\\b", 1), ("(?m)^\\s*import\\s+\\w+", 1), ("print\\(", 1)]),
            ("csharp", [("\\busing\\s+System", 4), ("\\bnamespace\\s+\\w+", 2), ("Console\\.", 2)]),
            ("java", [("\\bpublic\\s+(class|static|void)\\b", 3), ("System\\.out", 3), ("\\bnew\\s+\\w+\\s*\\(", 1)]),
            ("cpp", [("#include\\s*[<\"]", 3), ("std::", 3), ("\\bcout\\b", 2), ("\\btemplate\\s*<", 2)]),
            ("c", [("#include\\s*[<\"]", 3), ("\\bprintf\\s*\\(", 2), ("\\bmalloc\\b", 2)]),
            ("typescript", [(":\\s*(string|number|boolean|void|any)\\b", 3), ("\\binterface\\s+\\w+", 2), ("\\bconst\\s+\\w+\\s*=", 1), ("=>", 1)]),
            ("javascript", [("\\bconst\\s+\\w+\\s*=", 2), ("=>", 2), ("\\bfunction\\b", 2), ("console\\.", 2), ("===", 2)]),
            ("ruby", [("(?m)^\\s*end\\s*$", 2), ("\\bputs\\s", 2), ("\\bdef\\s+\\w+\\s*$", 2), ("\\brequire\\s+['\"]", 2)]),
            ("css", [("(?m)^\\s*[.#]?[\\w-]+\\s*\\{\\s*$", 2), ("(?m)^\\s*[\\w-]+\\s*:\\s*[^;{]+;\\s*$", 2), ("@media\\b", 3)]),
            ("yaml", [("(?m)^[\\w-]+:\\s+\\S", 2), ("(?m)^\\s*-\\s+\\w", 1)]),
        ]

        var best: (language: String, score: Int)?
        for (language, patterns) in rules {
            var score = 0
            for (pattern, weight) in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
                score += weight
            }
            if score >= 3, score > (best?.score ?? 0) {
                best = (language, score)
            }
        }
        return best?.language
    }
}
