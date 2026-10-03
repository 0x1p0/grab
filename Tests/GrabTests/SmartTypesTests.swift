import XCTest
@testable import Grab

final class SmartTypesTests: XCTestCase {
    private func detect(_ t: String, near w: String? = nil) -> SmartValue? { SmartTypes.detect(t, near: w) }

    private func text(_ v: SmartValue?, _ id: String) -> String? {
        guard let v, case .text(let t)? = SmartTypes.render(v, as: id) else { return nil }
        return t
    }

    private func link(_ v: SmartValue?, _ id: String) -> URL? {
        guard let v, case .link(let u)? = SmartTypes.render(v, as: id) else { return nil }
        return u
    }

    func testMath() {
        let v = detect("1,240 × 12%")
        XCTAssertEqual(v?.kind, .math)
        XCTAssertEqual(text(v, "result"), "148.8")
        XCTAssertEqual(text(detect("(2 + 3) * 4 ^ 2"), "result"), "80")
        XCTAssertEqual(text(detect("10 / 4"), "result"), "2.5")
        XCTAssertEqual(text(detect("4 x 12"), "result"), "48")
        // Not sums: dates, ranges, sizes, phone numbers.
        XCTAssertNotEqual(detect("2024-10-02")?.kind, .math)
        XCTAssertNotEqual(detect("10-20")?.kind, .math)
        XCTAssertNotEqual(detect("1920x1080")?.kind, .math)
        XCTAssertNotEqual(detect("555-123-4567")?.kind, .math)
        XCTAssertNil(MathParser.evaluate("1 / 0"))
        XCTAssertNil(MathParser.evaluate("2 +"))
    }

    func testJSON() {
        let v = detect(#"{"b":1,"a":[1,2]}"#)
        XCTAssertEqual(v?.kind, .json)
        XCTAssertEqual(text(v, "min"), #"{"b":1,"a":[1,2]}"#)
        XCTAssertEqual(text(v, "pretty"), "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    2\n  ]\n}")
        XCTAssertEqual(SmartTypes.minifiedJSON(#"{ "s": "a, b: {c}", "e": {}, "n": 1.50 }"#), #"{"s":"a, b: {c}","e":{},"n":1.50}"#)
        XCTAssertNil(detect("{not json}").flatMap { $0.kind == .json ? $0 : nil })
    }

    func testJWT() {
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"sub":"1234567890","name":"Ada"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let v = detect("\(header).\(payload).c2lnbmF0dXJl")
        XCTAssertEqual(v?.kind, .jwt)
        XCTAssertTrue(text(v, "payload")?.contains("Ada") == true)
        XCTAssertTrue(text(v, "header")?.contains("HS256") == true)
    }

    func testBase64AndTimestamp() {
        let v = detect("SGVsbG8sIEdyYWIhIEhvdyBhcmUgeW91Pw==")
        XCTAssertEqual(v?.kind, .base64)
        XCTAssertEqual(text(v, "decoded"), "Hello, Grab! How are you?")
        // A git hash is not base64.
        XCTAssertNotEqual(detect("3f786850e387550fdab836ed7e6dc881de23001b")?.kind, .base64)

        let ts = detect("1759400000")
        XCTAssertEqual(ts?.kind, .timestamp)
        XCTAssertEqual(ts?.date, Date(timeIntervalSince1970: 1_759_400_000))
        XCTAssertEqual(detect("1759400000123")?.date, Date(timeIntervalSince1970: 1_759_400_000.123))
        XCTAssertNil(detect("1234567890123456"))
    }

    func testDatesAndEvents() {
        let v = detect("Team sync on October 7, 2026 at 3:00 PM")
        XCTAssertEqual(v?.kind, .date)
        XCTAssertEqual(v?.hasTime, true)
        XCTAssertEqual(v?.context, "Team sync")
        if case .event(let ics, _)? = v.flatMap({ SmartTypes.render($0, as: "ics") }) {
            XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
            XCTAssertTrue(ics.contains("SUMMARY:Team sync\r\n"))
        } else {
            XCTFail("no event")
        }
        let day = detect("Due March 3, 2027")
        XCTAssertEqual(day?.hasTime, false)
        XCTAssertEqual(text(day, "iso"), "2027-03-03")
    }

    func testPhoneEmailAddress() {
        XCTAssertEqual(SmartTypes.e164("(555) 123-4567", region: "US"), "+15551234567")
        XCTAssertEqual(SmartTypes.e164("(555) 123-4567", region: "IN"), "+15551234567")
        XCTAssertEqual(SmartTypes.e164("98765 43210", region: "IN"), "+919876543210")
        XCTAssertEqual(SmartTypes.e164("020 7946 0958", region: "GB"), "+442079460958")
        XCTAssertEqual(SmartTypes.e164("+49 30 1234567", region: "US"), "+49301234567")
        XCTAssertEqual(SmartTypes.e164("0044 20 7946 0958", region: "US"), "+442079460958")

        let phone = detect("Call (555) 123-4567 today", near: "123")
        XCTAssertEqual(phone?.kind, .phone)
        XCTAssertEqual(link(phone, "tel")?.scheme, "tel")

        let mail = detect("Write to hello@example.com")
        XCTAssertEqual(mail?.kind, .email)
        XCTAssertEqual(text(mail, "address"), "hello@example.com")

        let addr = detect("1 Infinite Loop, Cupertino, CA 95014")
        XCTAssertEqual(addr?.kind, .address)
        XCTAssertEqual(link(addr, "apple")?.host, "maps.apple.com")
    }

    func testMoneyAndMeasures() {
        let m = detect("Only $1,299.99")
        XCTAssertEqual(m?.kind, .money)
        XCTAssertEqual(m?.currency, "USD")
        XCTAssertEqual(text(m, "number"), "1299.99")
        XCTAssertEqual(detect("€45")?.currency, "EUR")
        XCTAssertEqual(detect("12.50 EUR")?.number, 12.5)
        XCTAssertEqual(detect("$2.5M raised")?.number, 2_500_000)

        let len = detect("12 ft")
        XCTAssertEqual(len?.kind, .measure)
        XCTAssertNotNil(text(len, "convert"))
        XCTAssertEqual(detect("72°F")?.kind, .measure)
        XCTAssertNil(Measures.convert(3, unit: "parsecs"))
    }

    func testLookups() {
        let ups = detect("Your package 1Z999AA10123456784 is on its way", near: "1Z999AA10123456784")
        XCTAssertEqual(ups?.kind, .tracking)
        XCTAssertEqual(link(ups, "link")?.host, "www.ups.com")
        XCTAssertNil(detect("Order 123456789012").flatMap { $0.kind == .tracking ? $0 : nil })
        XCTAssertEqual(detect("FedEx 123456789012")?.kind, .tracking)

        let isbn = detect("ISBN 978-0-306-40615-7")
        XCTAssertEqual(isbn?.kind, .isbn)
        XCTAssertEqual(text(isbn, "value"), "9780306406157")
        XCTAssertFalse(SmartTypes.validISBN("9780306406158"))

        let doi = detect("doi:10.1038/nphys1170")
        XCTAssertEqual(doi?.kind, .doi)
        XCTAssertEqual(link(doi, "link")?.absoluteString, "https://doi.org/10.1038/nphys1170")
    }

    func testErrors() {
        let py = """
        Traceback (most recent call last):
          File "/usr/lib/python3.12/site-packages/x.py", line 3, in <module>
            main()
          File "/Users/me/app.py", line 9, in main
            raise ValueError("bad thing")
        ValueError: bad thing
        """
        let v = detect(py)
        XCTAssertEqual(v?.kind, .error)
        XCTAssertEqual(text(v, "line"), "ValueError: bad thing")
        XCTAssertFalse(text(v, "clean")?.contains("site-packages") ?? true)

        let js = """
        TypeError: Cannot read properties of undefined (reading 'map')
            at render (/app/src/List.tsx:12:5)
            at Object.run (/app/node_modules/react/index.js:1:1)
        """
        let j = detect(js)
        XCTAssertEqual(text(j, "line"), "TypeError: Cannot read properties of undefined (reading 'map')")
        XCTAssertEqual(SmartTypes.searchQuery(forError: "Error at /Users/me/x.swift:12:4 0xdeadbeef"), "Error at")

        XCTAssertEqual(detect("main.swift:12:5: error: cannot find 'x' in scope")?.kind, .error)
        // A page that merely contains a trace is not an error.
        let page = (1...30).map { "Paragraph \($0) of an ordinary page about fruit." }.joined(separator: "\n") + "\n" + js
        XCTAssertNotEqual(detect(page)?.kind, .error)
        XCTAssertNil(detect("No errors here, all good"))
    }

    func testWordChoosesEntityInLongText() {
        let para = String(repeating: "Lorem ipsum dolor sit amet. ", count: 8) + "Meet me on Friday at 5pm or call (555) 123-4567. " + String(repeating: "More filler text here. ", count: 4)
        let a = SmartTypes.analyze(para)
        XCTAssertEqual(SmartTypes.choose(a, near: "4567")?.kind, .phone)
        XCTAssertEqual(SmartTypes.choose(a, near: "Friday")?.kind, .date)
        XCTAssertNil(SmartTypes.choose(a, near: "Lorem"))
    }

    func testPlainTextStaysPlain() {
        XCTAssertNil(detect("The quick brown fox jumps over the lazy dog"))
        XCTAssertNil(detect("Hello"))
    }
}

final class FormatsTests: XCTestCase {
    func testListsTablesAndCitations() {
        XCTAssertEqual(Formats.list("a\nb\n\nc", as: "bullets"), "- a\n- b\n- c")
        XCTAssertEqual(Formats.list("a\nb", as: "numbered"), "1. a\n2. b")
        XCTAssertEqual(Formats.list("a\nb", as: "comma"), "a, b")
        XCTAssertEqual(Formats.list("a\n\"b\"", as: "json"), #"["a", "\"b\""]"#)
        XCTAssertEqual(Formats.table("name\tage\nAda\t36", as: "json"), "[\n  {\"name\": \"Ada\", \"age\": \"36\"}\n]")
        XCTAssertEqual(Formats.cite("Hi", title: "Page", url: URL(string: "https://x.com")), "“Hi”\n— Page (https://x.com)")
        XCTAssertEqual(Formats.jsonString([("Name", "Ada"), ("OK", "true")]), "{\n  \"Name\": \"Ada\",\n  \"OK\": \"true\"\n}")
    }

    func testGitRemotes() {
        XCTAssertEqual(Git.webURL("git@github.com:apple/swift.git")?.0.absoluteString, "https://github.com/apple/swift")
        XCTAssertEqual(Git.webURL("https://gitlab.com/group/sub/repo.git")?.1, "GitLab")
        XCTAssertNil(Git.webURL("https://example.com/repo.git"))
        let config = """
        [core]
            bare = false
        [remote "upstream"]
            url = git@github.com:a/b.git
        [remote "origin"]
            url = https://github.com/me/b.git
        """
        XCTAssertEqual(Git.originURL(config), "https://github.com/me/b.git")
    }

    func testSecrets() {
        XCTAssertTrue(Secrets.looksSecret("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"))
        XCTAssertTrue(Secrets.looksSecret("ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"))
        XCTAssertTrue(Secrets.looksSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(Secrets.looksSecret("Xk9pQ2vL7mN4rT8wZ1yB6cD3fG5hJ0aE"))
        XCTAssertFalse(Secrets.looksSecret("3f786850e387550fdab836ed7e6dc881de23001b"))
        XCTAssertFalse(Secrets.looksSecret("https://example.com/some/long/path/to/a/page"))
        XCTAssertFalse(Secrets.looksSecret("Just a normal sentence with words"))
        XCTAssertFalse(Secrets.looksSecret("UIApplicationDidBecomeActive2Notification"))
        XCTAssertFalse(Secrets.looksSecret("com.example.MyApp.Feature2024Release"))
    }

    func testAdaptivePaste() {
        let session = "$ npm test\nall 14 tests passed\nok\n$ git status"
        XCTAssertEqual(AdaptiveText.adapt(session, language: "console", for: "com.apple.Terminal"), "npm test\ngit status")
        XCTAssertEqual(AdaptiveText.adapt("let x = 1", language: "swift", for: "com.tinyspeck.slackmacgap"), "`let x = 1`")
        XCTAssertEqual(AdaptiveText.adapt("a\nb", language: "swift", for: "md.obsidian"), "```swift\na\nb\n```")
        XCTAssertEqual(AdaptiveText.adapt("a\nb", language: "swift", for: "com.apple.TextEdit"), "a\nb")
    }

    func testListMarkers() {
        XCTAssertEqual(Inspector.strippingMarkers(["• Apples", "• Bananas"]), ["Apples", "Bananas"])
        XCTAssertEqual(Inspector.strippingMarkers(["1. One", "2. Two"]), ["One", "Two"])
        XCTAssertEqual(Inspector.strippingMarkers(["1. One", "3. Three"]), ["1. One", "3. Three"])
    }

    func testVideoTimesAndSelectors() {
        XCTAssertEqual(Inspector.seconds("1:02:03"), 3723)
        XCTAssertEqual(Inspector.seconds("4:05"), 245)
        XCTAssertNil(Inspector.seconds("live"))
        XCTAssertEqual(Inspector.timestampablePage(URL(string: "https://www.youtube.com/watch?v=abc123&list=x")!)?.absoluteString,
                       "https://youtu.be/abc123")
        XCTAssertNil(Inspector.timestampablePage(URL(string: "https://example.com/watch?v=1")!))
        XCTAssertEqual(Inspector.weight(of: "Inter-SemiBold"), 600)
        XCTAssertEqual(Inspector.weight(of: "SFPro-Regular"), 400)
    }
}
