import XCTest
@testable import Grab

final class CodeIntelTests: XCTestCase {
    private func scopes(_ code: String, at marker: String, _ lang: CodeLanguage, terminal: Bool = false) -> (CodeAnalysis, [CodeScope], Int) {
        let idx = (code as NSString).range(of: marker).location
        precondition(idx != NSNotFound, "marker \(marker) not found")
        let a = CodeAnalysis(text: code, language: lang, terminal: terminal)
        let (s, d) = a.scopes(at: idx)
        return (a, s, d)
    }

    private func labels(_ s: [CodeScope]) -> [String] { s.map(\.label) }

    let swift = """
    import Foundation

    /// Adds two numbers.
    func add(_ a: Int, _ b: Int) -> Int {
        return a + b
    }

    struct Greeter {
        let name: String

        @MainActor
        func greet(loudly: Bool) -> String {
            if name.isEmpty {
                return "Hello!"
            } else {
                let text = "Hello, \\(name)!"
                return loudly ? text.uppercased() : text
            }
        }
    }
    """

    func testSwiftFunctionFromHeaderIsDefault() {
        let (a, s, d) = scopes(swift, at: "add(_ a", .swift)
        XCTAssertEqual(s[d].kind, .function)
        XCTAssertEqual(s[d].label, "Function · add")
        XCTAssertEqual(a.copyText(s[d]), "/// Adds two numbers.\nfunc add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}")
    }

    func testSwiftLineInsideIsDefaultWithBlocksAbove() {
        let (a, s, d) = scopes(swift, at: "uppercased", .swift)
        XCTAssertEqual(s[d].kind, .line)
        XCTAssertEqual(a.copyText(s[d]), "return loudly ? text.uppercased() : text")
        let l = labels(s)
        XCTAssertTrue(l.contains("Symbol · uppercased"), "\(l)")
        XCTAssertTrue(l.contains("else block"), "\(l)")
        XCTAssertTrue(l.contains("if statement"), "\(l)")
        XCTAssertTrue(l.contains("Function · greet"), "\(l)")
        XCTAssertTrue(l.contains("Struct · Greeter"), "\(l)")
        let fn = s.first { $0.label == "Function · greet" }!
        XCTAssertTrue(a.copyText(fn).hasPrefix("@MainActor\nfunc greet(loudly: Bool) -> String {"), a.copyText(fn))
        XCTAssertTrue(a.copyText(fn).hasSuffix("        }\n    }\n}") == false)
        XCTAssertTrue(a.copyText(fn).hasSuffix("    }\n}"), a.copyText(fn))
    }

    func testExpressionAndString() {
        let (a, s, _) = scopes(swift, at: "uppercased", .swift)
        let expr = s.first { $0.kind == .expression }!
        XCTAssertEqual(a.copyText(expr), "text.uppercased()")
        let (a2, s2, _) = scopes(swift, at: "Hello!", .swift)
        let str = s2.first { $0.kind == .string }!
        XCTAssertEqual(a2.copyText(str), "Hello!")
    }

    func testClosingBraceSelectsBlock() {
        let code = "func a() {\n    if x {\n        y()\n    }\n}\n"
        let idx = (code as NSString).range(of: "    }").location + 4
        let an = CodeAnalysis(text: code, language: .swift)
        let (s, d) = an.scopes(at: idx)
        XCTAssertEqual(s[d].label, "if block")
    }

    func testMultilineStatement() {
        let code = "let status = UCKeyTranslate(\n    layout, 0,\n    &dead\n)\nprint(status)\n"
        let (a, s, d) = scopes(code, at: "layout", .swift)
        XCTAssertEqual(s[d].kind, .line)
        let st = s.first { $0.kind == .statement }!
        XCTAssertEqual(a.copyText(st), "let status = UCKeyTranslate(\n    layout, 0,\n    &dead\n)")
    }

    func testPython() {
        let py = """
        class Greeter:
            \"\"\"Says hello.\"\"\"

            def __init__(self, name):
                self.name = name

            @property
            def greeting(self):
                if self.name:
                    return f"Hello, {self.name}!"
                return "Hello!"


        def main():
            print("hi")
        """
        let (a, s, d) = scopes(py, at: "return f", .python)
        XCTAssertEqual(s[d].kind, .line)
        let l = labels(s)
        XCTAssertTrue(l.contains("if block"), "\(l)")
        XCTAssertTrue(l.contains("Function · greeting"), "\(l)")
        XCTAssertTrue(l.contains("Class · Greeter"), "\(l)")
        let fn = s.first { $0.label == "Function · greeting" }!
        XCTAssertEqual(a.copyText(fn), "@property\ndef greeting(self):\n    if self.name:\n        return f\"Hello, {self.name}!\"\n    return \"Hello!\"")
        let (_, s2, d2) = scopes(py, at: "def main", .python)
        XCTAssertEqual(s2[d2].label, "Function · main")
    }

    func testJavaScript() {
        let js = """
        export const handler = async (event) => {
          const items = event.records.map((r) => r.id);
          for (const id of items) {
            await save(id);
          }
          return { ok: true };
        };

        class Store {
          constructor(db) {
            this.db = db;
          }
          async save(id) {
            return this.db.put(`item:${id}`, { id });
          }
        }
        """
        let (_, s, _) = scopes(js, at: "await save", .javascript)
        let l = labels(s)
        XCTAssertTrue(l.contains("for loop"), "\(l)")
        XCTAssertTrue(l.contains("Function · handler"), "\(l)")
        let (_, s2, d2) = scopes(js, at: "async save", .javascript)
        XCTAssertEqual(s2[d2].label, "Function · save")
        XCTAssertTrue(labels(s2).contains("Class · Store"))
        let (_, s3, _) = scopes(js, at: "item:", .javascript)
        XCTAssertTrue(s3.contains { $0.kind == .string })
    }

    func testGoAndRust() {
        let go = "func (s *Server) Handle(w http.ResponseWriter) {\n\tw.Write(nil)\n}\n"
        let (_, s, d) = scopes(go, at: "Handle", .go)
        XCTAssertEqual(s[d].label, "Function · Handle")
        let rs = "impl Display for Point {\n    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {\n        write!(f, \"({}, {})\", self.x, self.y)\n    }\n}\n"
        let (_, s2, _) = scopes(rs, at: "write!", .rust)
        let l = labels(s2)
        XCTAssertTrue(l.contains("Function · fmt"), "\(l)")
        XCTAssertTrue(l.contains("Impl · Display for Point"), "\(l)")
    }

    func testTerminal() {
        let term = "Last login: Thu\nthirteen@Mac ~ % ls -la ~/Projects\ntotal 8\ndrwxr-xr-x  3 me  staff  96 Oct 1 a\nthirteen@Mac ~ % git status\nOn branch main\n"
        let (a, s, d) = scopes(term, at: "ls -la", .shell, terminal: true)
        XCTAssertEqual(s[d].kind, .command)
        XCTAssertEqual(a.copyText(s[d]), "ls -la ~/Projects")
        let (a2, s2, _) = scopes(term, at: "total 8", .shell, terminal: true)
        let out = s2.first { $0.kind == .output }!
        XCTAssertEqual(a2.copyText(out), "total 8\ndrwxr-xr-x  3 me  staff  96 Oct 1 a")
        let (a3, s3, _) = scopes(term, at: "Projects", .shell, terminal: true)
        XCTAssertEqual(a3.copyText(s3.first { $0.kind == .symbol }!), "~/Projects")
    }

    func testLooksLikeCode() {
        XCTAssertTrue(CodeAnalysis.looksLikeCode(swift))
        XCTAssertFalse(CodeAnalysis.looksLikeCode("The quick brown fox jumps over the lazy dog.\nAnother sentence here, nothing special."))
        XCTAssertTrue(CodeAnalysis.looksLikeCode("let x = 42"))
    }

    func testLanguageNames() {
        XCTAssertEqual(CodeLanguage.named("language-swift")?.name, "swift")
        XCTAssertEqual(CodeLanguage.named("highlight-source-ts")?.name, "typescript")
        XCTAssertEqual(CodeLanguage.forFile(URL(fileURLWithPath: "/a/b.py"))?.name, "python")
        XCTAssertEqual(CodeLanguage.guess("def a():\n    pass\n").name, "python")
    }

    func testSmartData() {
        let line = "Sources/Grab/Engine/Session.swift:120:9: warning: variable"
        let url = SmartData.path(in: line, at: 10, cwd: URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(url?.path, "/repo/Sources/Grab/Engine/Session.swift")
        XCTAssertNil(SmartData.path(in: "if name.isEmpty {", at: 6, cwd: URL(fileURLWithPath: "/repo")))
        XCTAssertEqual(SmartData.path(in: "open ~/Desktop/a.png now", at: 8, cwd: nil)?.lastPathComponent, "a.png")
        XCTAssertEqual(SmartData.color(in: "  color: #ED6E2A;", at: 11)?.hex, "#ED6E2A")
        XCTAssertEqual(SmartData.color(in: "Color(hex: 0xED6E2A)", at: 13)?.hex, "#ED6E2A")
        XCTAssertEqual(SmartData.color(in: "background: rgb(237, 110, 42)", at: 16)?.hex, "#ED6E2A")
        XCTAssertNil(SmartData.color(in: "let add = 3", at: 5))
    }

    func testFormats() {
        XCTAssertEqual(Formats.number(in: "$12,480.50"), "12480.50")
        XCTAssertEqual(Formats.number(in: "1.234,56 €"), "1234.56")
        XCTAssertEqual(Formats.number(in: "12,480"), "12480")
        XCTAssertEqual(Formats.number(in: "2.1%"), "2.1")
        XCTAssertNil(Formats.number(in: "Revenue grew 23% year over year"))
        let w = Formats.wifi("WIFI:T:WPA;S:Grab\\;Cafe;P:hunter2;;")
        XCTAssertEqual(w.network, "Grab;Cafe")
        XCTAssertEqual(w.password, "hunter2")
        XCTAssertEqual(Formats.table("a\tb\n1\t2", as: "csv"), "a,b\n1,2")
        XCTAssertEqual(Formats.table("a\tb\n1\t2", as: "markdown"), "| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    /// Regression: a scope the cursor window misses left a null rect, and turning
    /// its infinite origin into an Int crashed the app.
    func testNonFiniteRectsNeverTrap() {
        let away = CGRect(x: 0, y: 0, width: 50, height: 50).intersection(CGRect(x: 900, y: 900, width: 10, height: 10))
        XCTAssertTrue(away.isNull)
        XCTAssertNil(away.gridKey)
        XCTAssertNil(CGRect.infinite.gridKey)
        XCTAssertNil(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10).gridKey)
        XCTAssertEqual(CGRect(x: 1.4, y: 2.6, width: 10, height: 10).gridKey, "1,2,11,11")
        XCTAssertEqual(CGFloat.nan.clampedInt, 0)
        XCTAssertEqual(CGFloat.infinity.clampedInt, 1_000_000_000)
        let grid = CodeGrid(lineHeight: 0, refLine: 0, refY: 0, left: 0, charWidth: 7, region: .zero)
        XCTAssertEqual(grid.line(atY: 40), -1)
    }
}
