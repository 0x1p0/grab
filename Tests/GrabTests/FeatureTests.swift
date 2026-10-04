import CryptoKit
import XCTest
@testable import Grab

final class TriggerTests: XCTestCase {
    private func flags(_ f: CGEventFlags, raw extra: UInt64 = 0) -> CGEventFlags {
        CGEventFlags(rawValue: f.rawValue | extra)
    }

    func testEitherOption() {
        XCTAssertTrue(KeyTap.split(flags(.maskAlternate), .option).held)
        XCTAssertEqual(KeyTap.split(flags([.maskAlternate, .maskShift]), .option).extra, .maskShift)
        XCTAssertFalse(KeyTap.split(flags(.maskCommand), .option).held)
    }

    func testRightOptionOnly() {
        // Right ⌥ alone: held. Left ⌥ alone: not held. Both: left counts as extra.
        XCTAssertTrue(KeyTap.split(flags(.maskAlternate, raw: 0x40), .rightOption).held)
        XCTAssertTrue(KeyTap.split(flags(.maskAlternate, raw: 0x40), .rightOption).extra.isEmpty)
        XCTAssertFalse(KeyTap.split(flags(.maskAlternate, raw: 0x20), .rightOption).held)
        XCTAssertTrue(KeyTap.split(flags(.maskAlternate, raw: 0x60), .rightOption).extra.contains(.maskAlternate))
    }

    func testCombinations() {
        XCTAssertFalse(KeyTap.split(flags(.maskAlternate), .controlOption).held)
        XCTAssertTrue(KeyTap.split(flags([.maskAlternate, .maskControl]), .controlOption).held)
        XCTAssertEqual(KeyTap.split(flags([.maskAlternate, .maskControl, .maskCommand]), .controlOption).extra, .maskCommand)
        let hyper: CGEventFlags = [.maskAlternate, .maskControl, .maskShift, .maskCommand]
        XCTAssertTrue(KeyTap.split(flags(hyper), .hyper).held)
        XCTAssertTrue(KeyTap.split(flags(hyper), .hyper).extra.isEmpty)
        XCTAssertFalse(KeyTap.split(flags([.maskAlternate, .maskControl]), .hyper).held)
    }

    func testTriggerText() {
        XCTAssertEqual(Trigger.option.chord("C"), "⌥C")
        XCTAssertEqual(Trigger.rightOption.chord("C"), "right ⌥C")
        XCTAssertFalse(Trigger.hyper.allowsShift)
    }
}

final class FormFillTests: XCTestCase {
    func testParsesGrabFieldsJSONInOrder() {
        let json = "{\n  \"Name\": \"Ada Lovelace\",\n  \"Email\": \"ada@example.com\",\n  \"Subscribe\": \"true\"\n}"
        let v = FormFill.parse(json)
        XCTAssertEqual(v.map(\.0), ["Name", "Email", "Subscribe"])
        XCTAssertEqual(v[1].1, "ada@example.com")
    }

    func testParsesLabelLines() {
        XCTAssertEqual(FormFill.parse("Name: Ada\nCity: London").map(\.1), ["Ada", "London"])
        XCTAssertEqual(FormFill.parse("Name\tAda\nCity\tLondon").map(\.0), ["Name", "City"])
        XCTAssertTrue(FormFill.parse("just a sentence").isEmpty)
        XCTAssertTrue(FormFill.parse("Note: one line only").isEmpty)
    }

    func testMatchesLabelsAcrossForms() {
        let values = [("Full name", "Ada"), ("E-mail", "ada@example.com"), ("Zip", "12345"), ("Phone", "555")]
        let fields = ["Name", "Email address", "Postal code", "Telephone", "Company"]
        let m = FormFill.match(fields: fields, values: values)
        XCTAssertEqual(m, [0, 1, 2, 3, nil])
    }

    func testEachValueUsedOnce() {
        let m = FormFill.match(fields: ["Email", "Email 2"], values: [("Email", "a@b.c")])
        XCTAssertEqual(m.compactMap { $0 }.count, 1)
    }
}

final class TextDiffTests: XCTestCase {
    func testWordDiff() {
        let r = TextDiff.compare("The quick brown fox", "The quick red fox")
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.added, 1)
        XCTAssertFalse(r.byLine)
        XCTAssertTrue(r.pieces.contains(TextDiff.Piece(kind: .removed, text: "brown")))
        XCTAssertTrue(r.pieces.contains(TextDiff.Piece(kind: .added, text: "red")))
        // The pieces put back together give the new text plus what was removed.
        let rebuilt = r.pieces.filter { $0.kind != .removed }.map(\.text).joined()
        XCTAssertEqual(rebuilt, "The quick red fox")
    }

    func testIdenticalAndLineMode() {
        XCTAssertTrue(TextDiff.compare("same", "same").identical)
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 7", with: "line seven")
        let r = TextDiff.compare(old, new)
        XCTAssertTrue(r.byLine)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
    }

    func testPatch() {
        let p = TextDiff.patch("a\nb\nc", "a\nB\nc")
        XCTAssertEqual(p, "--- clipboard\n+++ grabbed\n a\n-b\n+B\n c")
    }
}

final class TemplateTests: XCTestCase {
    func testTokensAndFilters() {
        let v = Template.values(text: "Hello World", url: URL(string: "https://example.com/a"), title: "Example", app: "Safari",
                                now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Template.render("[{title}]({url})", values: v), "[Example](https://example.com/a)")
        XCTAssertEqual(Template.render("{text|upper} {text|slug}", values: v), "HELLO WORLD hello-world")
        XCTAssertEqual(Template.render("{text|json}", values: v), "\"Hello World\"")
        XCTAssertEqual(Template.render("{nope} {text}", values: v), "{nope} Hello World")
        XCTAssertEqual(Template.render("a\\nb", values: v), "a\nb")
        XCTAssertEqual(Template.render("{ text | lower }", values: v), "hello world")
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(Updater.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2"))
        XCTAssertTrue(Updater.isNewer("1.2.0", than: "1.2.0-beta"))
        XCTAssertFalse(Updater.isNewer("1.2.0-beta", than: "1.2.0"))
    }

    func testParsesGitHubRelease() {
        let json = """
        {"tag_name":"v1.3.0","body":"**New**: boxes","html_url":"https://github.com/x/y/releases/tag/v1.3.0",
         "assets":[{"name":"Grab-1.3.0.dmg","browser_download_url":"https://x/Grab-1.3.0.dmg"},
                   {"name":"Grab-1.3.0.zip","browser_download_url":"https://x/Grab-1.3.0.zip"}]}
        """
        let r = Updater.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "1.3.0")
        XCTAssertEqual(r?.download.lastPathComponent, "Grab-1.3.0.zip")
        XCTAssertNil(Updater.parse(Data("{\"tag_name\":\"v1\",\"assets\":[]}".utf8)))
    }
}

final class HistoryVaultTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)/History.grabvault")
    }

    func testRecordsRoundTripEncrypted() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let vault = HistoryVault(url: url, key: key)
        var item = History.Item(mode: .link, payload: .link(URL(string: "https://example.com/secret-path")!), title: "x", thumbnail: nil, color: nil)
        item.appName = "Safari"
        vault.append(try XCTUnwrap(item.record()))
        vault.append(try XCTUnwrap(History.Item(mode: .text, payload: .text("hello vault"), title: "hello", thumbnail: nil, color: nil).record()))
        vault.flush()

        // Encrypted on disk: the text isn't readable in the file.
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("hello vault".utf8)))
        XCTAssertNil(raw.range(of: Data("secret-path".utf8)))

        let back = vault.load()
        XCTAssertEqual(back.count, 2)
        let restored = try XCTUnwrap(History.Item(record: back[0]))
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.appName, "Safari")
        if case .link(let u) = restored.payload { XCTAssertEqual(u.path, "/secret-path") } else { XCTFail("not a link") }

        // A different key opens nothing.
        XCTAssertTrue(HistoryVault(url: url, key: SymmetricKey(size: .bits256)).load().isEmpty)

        vault.rewrite(Array(back.suffix(1)))
        vault.flush()
        XCTAssertEqual(vault.load().map(\.title), ["hello"])
    }

    func testSecretsAndImages() throws {
        var secret = History.Item(mode: .text, payload: .text("sk-live-123"), title: "Secret", thumbnail: nil, color: nil)
        secret.isSecret = true
        XCTAssertNil(secret.record())

        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let img = ctx.makeImage()!
        let item = History.Item(mode: .image, payload: .image(img, pointSize: CGSize(width: 4, height: 4)), title: "Image", thumbnail: nil, color: nil)
        let r = try XCTUnwrap(item.record())
        XCTAssertEqual(r.kind, "image")
        let back = try XCTUnwrap(History.Item(record: r))
        if case .image(let i, let size) = back.payload {
            XCTAssertEqual(i.width, 8)
            XCTAssertEqual(size, CGSize(width: 4, height: 4))
        } else { XCTFail("not an image") }
    }
}

final class CodeImageTests: XCTestCase {
    func testHighlighting() {
        let pieces = CodeImage.highlight("let x = \"hi\" // note\nfunc launch() { return 42 }", language: "swift")
        func kind(of text: String) -> CodeImage.Token? { pieces.first { $0.text.contains(text) }?.token }
        XCTAssertEqual(kind(of: "let"), .keyword)
        XCTAssertEqual(kind(of: "\"hi\""), .string)
        XCTAssertEqual(kind(of: "// note"), .comment)
        XCTAssertEqual(kind(of: "launch"), .function)
        XCTAssertEqual(kind(of: "42"), .number)
        XCTAssertEqual(pieces.map(\.text).joined(), "let x = \"hi\" // note\nfunc launch() { return 42 }")
        XCTAssertEqual(CodeImage.highlight("# comment", language: "python").first?.token, .comment)
    }
}

final class StatsTests: XCTestCase {
    func testKindsAndTime() {
        func e(_ m: GrabMode, code: String? = nil, ocr: Bool = false, box: Bool = false) -> GrabEvent {
            GrabEvent(mode: m, text: nil, color: nil, bundleID: nil, codeKind: code, ocr: ocr, box: box, appended: false, format: nil, pixels: 0)
        }
        XCTAssertEqual(Stats.kind(of: e(.text)), .text)
        XCTAssertEqual(Stats.kind(of: e(.text, code: "function")), .code)
        XCTAssertEqual(Stats.kind(of: e(.text, ocr: true)), .ocr)
        XCTAssertEqual(Stats.kind(of: e(.image, box: true)), .box)
        XCTAssertEqual(Stats.saved(20), "a few seconds")
        XCTAssertEqual(Stats.saved(600), "10 min")
        XCTAssertEqual(Stats.saved(3 * 3600), "3.0 h")
        XCTAssertEqual(Stats.saved(5 * 86_400), "5 days")
    }

    func testFingerprintNoticesChange() {
        func solid(_ v: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            return ctx.makeImage()!
        }
        XCTAssertFalse(ImageFingerprint.differs(ImageFingerprint.of(solid(0.5)), ImageFingerprint.of(solid(0.5))))
        XCTAssertTrue(ImageFingerprint.differs(ImageFingerprint.of(solid(0.2)), ImageFingerprint.of(solid(0.8))))
    }
}

final class RoundedImageTests: XCTestCase {
    func testCornersBecomeTransparent() throws {
        let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let img = try XCTUnwrap(ctx.makeImage())
        let r = try XCTUnwrap(ImageTools.rounded(img, pointSize: CGSize(width: 100, height: 60)))
        XCTAssertEqual(r.width, 200)
        let rep = NSBitmapImageRep(cgImage: r)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 199, y: 119)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 100, y: 60)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 100, y: 0)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        // Tiny images are left alone.
        let tiny = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        XCTAssertNil(ImageTools.rounded(tiny, pointSize: CGSize(width: 10, height: 10)))
    }
}
