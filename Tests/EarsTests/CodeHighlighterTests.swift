import Testing
@testable import Ears

struct CodeHighlighterTests {

    // MARK: - Language detection

    @Test func detectsSwift() {
        let code = """
        import SwiftUI

        func greet(_ name: String) -> String {
            guard !name.isEmpty else { return "hey" }
            let message = "Hello, \\(name)"
            return message
        }
        """
        #expect(CodeHighlighter.detectLanguage(of: code) == "swift")
    }

    @Test func detectsPython() {
        let code = """
        def fib(n):
            if n <= 1:
                return n
            elif n == 2:
                return 1
            return fib(n - 1) + fib(n - 2)

        print(fib(10))
        """
        #expect(CodeHighlighter.detectLanguage(of: code) == "python")
    }

    @Test func detectsJavaScript() {
        let code = """
        const total = items.reduce((sum, item) => sum + item.price, 0);
        function render() {
            console.log(total === 0 ? "empty" : total);
        }
        """
        #expect(CodeHighlighter.detectLanguage(of: code) == "javascript")
    }

    @Test func detectsJSON() {
        let code = #"{"name": "Ears", "version": 2, "beta": true}"#
        #expect(CodeHighlighter.detectLanguage(of: code) == "json")
    }

    @Test func detectsSQL() {
        let code = "SELECT id, name FROM users WHERE active = 1 ORDER BY name"
        #expect(CodeHighlighter.detectLanguage(of: code) == "sql")
    }

    @Test func plainProseIsNotDetectedAsCode() {
        let prose = "Hey, can you check the numbers before the meeting? I think the totals are off."
        #expect(CodeHighlighter.detectLanguage(of: prose) == nil)
    }

    // MARK: - Highlighting

    @Test func highlightPreservesTextExactly() {
        let code = "func add(a: Int, b: Int) -> Int {\n\treturn a + b // sum\n}"
        let highlighted = CodeHighlighter.highlight(code, language: "swift")
        #expect(String(highlighted.characters) == code)
    }

    @Test func highlightColorsKeywordsDifferentlyFromPlainText() {
        let highlighted = CodeHighlighter.highlight("let x = identifier", language: "swift")
        var keywordColor: String?
        var plainColor: String?
        for run in highlighted.runs {
            let text = String(highlighted[run.range].characters)
            if text == "let" { keywordColor = String(describing: run.foregroundColor) }
            if text.contains("identifier") { plainColor = String(describing: run.foregroundColor) }
        }
        #expect(keywordColor != nil)
        #expect(plainColor != nil)
        #expect(keywordColor != plainColor)
    }

    @Test func unterminatedStringDoesNotSwallowFollowingLines() {
        let code = "let s = \"oops\nlet next = 1"
        let highlighted = CodeHighlighter.highlight(code, language: "swift")
        #expect(String(highlighted.characters) == code)
    }

    @Test func displayNames() {
        #expect(CodeHighlighter.displayName(for: "cpp") == "C++")
        #expect(CodeHighlighter.displayName(for: "js") == "JavaScript")
        #expect(CodeHighlighter.displayName(for: nil) == "Code")
        #expect(CodeHighlighter.displayName(for: "swift") == "Swift")
    }
}
