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
    private func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    func testCornersBecomeTransparent() throws {
        let img = image(200, 120) { $0.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 200, height: 120)) }
        let r = try XCTUnwrap(ImageTools.rounded(img, pointSize: CGSize(width: 100, height: 60)))
        XCTAssertEqual(r.image.width, 200)
        let rep = NSBitmapImageRep(cgImage: r.image)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 199, y: 119)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 100, y: 60)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 100, y: 0)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        let tiny = image(20, 20) { _ in }
        XCTAssertNil(ImageTools.rounded(tiny, pointSize: CGSize(width: 10, height: 10)))
    }

    /// A video player that's already rounded, captured with the white page behind its corners
    /// and a hairline of page along one edge: no white may be left in the result.
    func testNoPageLeftInTheCorners() throws {
        let w = 640, h = 360
        let img = image(w, h) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let player = CGRect(x: 2, y: 0, width: w - 2, height: h)   // 2 px of page down the left edge
            ctx.addPath(CGPath(roundedRect: player, cornerWidth: 30, cornerHeight: 30, transform: nil))
            ctx.setFillColor(CGColor(red: 0.25, green: 0.24, blue: 0.27, alpha: 1))
            ctx.fillPath()
        }
        let r = try XCTUnwrap(ImageTools.rounded(img, pointSize: CGSize(width: 320, height: 180)))
        XCTAssertEqual(r.image.width, w - 2, "the hairline of page is trimmed")
        XCTAssertEqual(r.pointSize.width, CGFloat(w - 2) / 2, accuracy: 0.01)
        let px = try XCTUnwrap(ImageTools.Pixels(r.image))
        var whiteLeft = 0
        for y in 0..<px.h {
            for x in 0..<px.w {
                let p = px.at(x, y)
                // Visible and close to white: a sliver of the page.
                if p.3 > 40 && p.0 > 200 && p.1 > 200 && p.2 > 200 { whiteLeft += 1 }
            }
        }
        XCTAssertEqual(whiteLeft, 0)
        XCTAssertEqual(px.at(px.w / 2, px.h / 2).3, 255)
    }

    /// A letterboxed video: dark bars around the picture that end a little way in. Those dark
    /// corners are the picture, not a page behind a rounded player (a rounded corner leaves
    /// the page along each edge for only about its radius), so the corners stay a soft 12 pt.
    func testDarkFramesKeepSoftCorners() throws {
        let w = 1000, h = 560, bar = 28
        let img = image(w, h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.075, green: 0.075, blue: 0.075, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.7, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: bar, y: bar, width: w - bar * 2, height: h - bar * 2))
        }
        let r = try XCTUnwrap(ImageTools.rounded(img, pointSize: CGSize(width: 500, height: 280)))
        let px = try XCTUnwrap(ImageTools.Pixels(r.image))
        // A 12 pt continuous corner at 2× cuts about 5 px in at 45°.
        var d = 0
        while px.at(d, d).3 < 128 { d += 1 }
        XCTAssertLessThanOrEqual(d, 7)
    }

    /// Where the ink is in a picture: (left, top, right, bottom) margins in pixels.
    private func margins(_ px: ImageTools.Pixels, from bg: (Int, Int, Int, Int)) -> (Int, Int, Int, Int) {
        var minX = px.w, maxX = -1, minY = px.h, maxY = -1
        for y in 0..<px.h {
            for x in 0..<px.w {
                let p = px.at(x, y)
                guard p.3 > 200, !ImageTools.Pixels.near(p, bg, 40) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return (minX, minY, px.w - 1 - maxX, px.h - 1 - maxY)
    }

    /// Text that hugs one edge and floats away from another comes out with the same room on
    /// every side, in its own background color; text over a busy picture is left alone.
    func testTextGetsEvenRoom() throws {
        let text = image(600, 80) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 80))
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            // Two "lines" of letters, 30 px tall: touching the left and top, far from the right.
            for line in 0..<2 {
                for i in 0..<(line == 0 ? 8 : 5) { ctx.fill(CGRect(x: i * 40, y: 80 - 30 - line * 40, width: 28, height: 30)) }
            }
        }
        let card = try XCTUnwrap(ImageTools.textCard(text, pointSize: CGSize(width: 300, height: 40)))
        let px = try XCTUnwrap(ImageTools.Pixels(card.image))
        let source = try XCTUnwrap(ImageTools.Pixels(text))
        let bg = source.at(599, 79)
        let m = margins(px, from: bg)
        // 15 pt lines → about 16.5 pt of room (33 px at 2×) on every side.
        XCTAssertEqual(m.0, m.2)
        XCTAssertEqual(m.1, m.3)
        XCTAssertEqual(m.0, m.1)
        XCTAssertEqual(m.0, 33, accuracy: 3)
        XCTAssertEqual(card.pointSize.width, CGFloat(px.w) / 2, accuracy: 0.01)
        XCTAssertTrue(ImageTools.Pixels.near(px.at(2, 2), bg, 1), "the room is the background color")

        let busy = image(200, 60) { ctx in
            for i in 0..<20 {
                ctx.setFillColor(CGColor(red: CGFloat(i % 3) / 2, green: CGFloat(i % 5) / 4, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: i * 10, y: 0, width: 10, height: 60))
            }
        }
        XCTAssertNil(ImageTools.textCard(busy, pointSize: CGSize(width: 100, height: 30)))
    }

    /// Text in a bordered, rounded box on a darker page: the border and the page in its
    /// corners stay behind, only the writing is framed.
    func testBoxAroundTextIsLeftOut() throws {
        let w = 500, h = 90
        let img = image(w, h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let box = CGPath(roundedRect: CGRect(x: 1, y: 1, width: w - 2, height: h - 2), cornerWidth: 20, cornerHeight: 20, transform: nil)
            ctx.addPath(box)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
            ctx.addPath(box)
            ctx.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.75, blue: 0.78, alpha: 1))
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            for i in 0..<6 { ctx.fill(CGRect(x: 30 + i * 36, y: 30, width: 26, height: 28)) }
        }
        let card = try XCTUnwrap(ImageTools.textCard(img, pointSize: CGSize(width: 250, height: 45)))
        let px = try XCTUnwrap(ImageTools.Pixels(card.image))
        // Only the letters and white room: no grey border or page anywhere.
        var stray = 0
        for y in 0..<px.h {
            for x in 0..<px.w {
                let p = px.at(x, y)
                if p.0 > 40 && p.0 < 240 { stray += 1 }
            }
        }
        XCTAssertEqual(stray, 0)
        let m = margins(px, from: (255, 255, 255, 255))
        XCTAssertEqual(m.0, m.2)
        XCTAssertEqual(m.1, m.3)
        XCTAssertEqual(px.w - m.0 - m.2, 5 * 36 + 26, "cropped to the letters")
    }
}

/// Clearing history from the menu: everything goes, Undo brings it back (with anything
/// grabbed since), and the menu changes height without leaving the menu bar.
@MainActor
final class MenuPanelTests: XCTestCase {
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }

    func testClearHistoryAndUndo() throws {
        // Memory-only history: never near a saved one.
        try XCTSkipIf(Settings.shared.keepHistory)
        _ = NSApplication.shared
        History.shared.clear()
        defer { History.shared.clear() }
        for t in ["first", "second", "third", "fourth", "fifth"] {
            History.shared.add(History.Item(mode: .text, payload: .text(t), title: t, thumbnail: nil, color: nil))
        }
        let view = MenuPanelView(frontApp: nil, actions: .init(
            copy: { _ in }, close: {}, history: {}, shelf: {}, settings: {}, welcome: {}, updates: {},
            showUpdate: {}, pause: {}, toggleApp: { _ in }, prefer: { _, _ in }, quit: {}))
        let panel = MenuPanel(content: view)
        let size = try XCTUnwrap(panel.contentView?.fittingSize)
        // Far off every screen, never key: nothing shows and nothing loses focus.
        panel.setFrame(NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height), display: true)
        panel.top = panel.frame.maxY
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        spin()
        let full = panel.frame

        panel.model.send(.clearHistory)
        spin()
        XCTAssertTrue(History.shared.items.isEmpty)
        XCTAssertLessThan(panel.frame.height, full.height)
        XCTAssertEqual(panel.frame.maxY, full.maxY, accuracy: 0.5, "the top stays under the menu bar")

        History.shared.add(History.Item(mode: .text, payload: .text("sixth"), title: "sixth", thumbnail: nil, color: nil))
        panel.model.send(.undoClear)
        spin()
        XCTAssertEqual(History.shared.items.map(\.title), ["sixth", "fifth", "fourth", "third", "second", "first"])
        XCTAssertEqual(panel.frame.height, full.height, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, full.maxY, accuracy: 0.5)
    }
}

/// A throwaway defaults suite, removed after each test.
private final class TestDefaults {
    let name = "grab.tests.\(UUID().uuidString)"
    lazy var d = UserDefaults(suiteName: name)!
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

final class BuddyTests: XCTestCase {
    func testCombosNeedQuickGrabs() {
        let t = TestDefaults()
        let b = Buddy(defaults: t.d)
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(b.grabbed(at: start), 1)
        XCTAssertEqual(b.grabbed(at: start.addingTimeInterval(2)), 2)
        XCTAssertEqual(b.grabbed(at: start.addingTimeInterval(6)), 3)
        XCTAssertEqual(b.grabbed(at: start.addingTimeInterval(20)), 1, "too slow: the combo starts over")
    }

    func testPokingTooMuchSendsItAway() {
        let t = TestDefaults()
        let b = Buddy(defaults: t.d)
        let now = Date()
        for i in 1...4 { XCTAssertEqual(b.pet(at: now.addingTimeInterval(Double(i))), .giggle(i)) }
        XCTAssertEqual(b.pet(at: now.addingTimeInterval(5)), .annoyed)
        XCTAssertEqual(b.mood(at: now.addingTimeInterval(30)), .away)
        XCTAssertNotEqual(b.mood(at: now.addingTimeInterval(70)), .away, "back after a minute")
        XCTAssertEqual(b.petsTotal, 5)
    }

    func testMoods() {
        let t = TestDefaults()
        let b = Buddy(defaults: t.d)
        let now = Date()
        b.grabbed(at: now)
        XCTAssertEqual(b.mood(at: now.addingTimeInterval(60)), .normal)
        XCTAssertEqual(b.mood(at: now.addingTimeInterval(Buddy.sleepAfter + 1)), .sleepy)
        XCTAssertTrue(b.wake(at: now.addingTimeInterval(Buddy.sleepAfter + 2)), "holding ⌥ wakes it")
        XCTAssertNotEqual(b.mood(at: now.addingTimeInterval(Buddy.sleepAfter + 3)), .sleepy)
        let day = Calendar.current.startOfDay(for: now).addingTimeInterval(13 * 3600)
        for i in 0..<Buddy.pumpedAt { b.grabbed(at: day.addingTimeInterval(Double(i) * 30)) }
        XCTAssertEqual(b.mood(at: day.addingTimeInterval(Double(Buddy.pumpedAt) * 30)), .pumped)
    }

    func testOutfits() {
        let t = TestDefaults()
        let b = Buddy(defaults: t.d)
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let night = Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 3600)
        XCTAssertEqual(b.outfit(at: noon, total: 99, wear: true), Buddy.Outfit())
        XCTAssertEqual(b.outfit(at: noon, total: 100, wear: true), Buddy.Outfit(shades: true))
        XCTAssertEqual(b.outfit(at: noon, total: 1_000, wear: true), Buddy.Outfit(shades: true, crown: true))
        XCTAssertEqual(b.outfit(at: night, total: 1_000, wear: true), Buddy.Outfit(crown: true, nightcap: true), "no sunglasses at night")
        XCTAssertEqual(b.outfit(at: noon, total: 5_000, wear: false), Buddy.Outfit())
    }

    func testComboClimbsAScale() {
        XCTAssertEqual((1...9).map(Session.comboPitch), [0, 2, 4, 5, 7, 9, 11, 12, 12])
    }
}

final class BadgeTests: XCTestCase {
    private func event(_ mode: GrabMode = .text, text: String? = "hello") -> GrabEvent {
        GrabEvent(mode: mode, text: text, color: nil, bundleID: "com.apple.Safari", codeKind: nil, ocr: false, box: false,
                  appended: false, format: nil, pixels: 0)
    }

    func testTimeAndComboBadges() {
        let t = TestDefaults()
        let b = Badges(defaults: t.d)
        let three = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3 * 3600)
        XCTAssertTrue(b.check(event(), combo: 1, at: three).contains(.nightOwl))
        XCTAssertFalse(b.check(event(), combo: 1, at: three).contains(.nightOwl), "once")
        XCTAssertTrue(b.check(event(), combo: 10, at: three.addingTimeInterval(60)).contains(.comboKing))
        XCTAssertEqual(b.progress(.comboKing)?.0, 10)
        XCTAssertTrue(Badges(defaults: t.d).has(.nightOwl), "kept")
    }

    func testStreakAndLanguages() {
        let t = TestDefaults()
        let b = Badges(defaults: t.d)
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        var got: [Badge] = []
        for day in 0..<7 { got += b.check(event(), combo: 1, at: noon.addingTimeInterval(Double(day) * 86_400)) }
        XCTAssertTrue(got.contains(.onARoll))
        XCTAssertEqual(Badges.language(of: "The quick brown fox jumps over the lazy dog near the river bank."), "en")
        XCTAssertEqual(Badges.language(of: "Le renard brun rapide saute par-dessus le chien paresseux près de la rivière."), "fr")
        XCTAssertNil(Badges.language(of: "ok"), "too short to tell")
    }

    func testPets() {
        let t = TestDefaults()
        let b = Badges(defaults: t.d)
        XCTAssertEqual(b.checkPet(.annoyed, total: 5), [.testingPatience])
        XCTAssertEqual(b.checkPet(.giggle(1), total: 25), [.bestFriends])
    }
}

final class JournalTests: XCTestCase {
    func testAMonthOfGrabs() {
        let t = TestDefaults()
        let j = Journal(defaults: t.d)
        let cal = Calendar.current
        let first = cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        for day in [0, 1, 2, 5] {
            let e = GrabEvent(mode: .text, text: String(repeating: "a", count: 300 + day), color: nil, bundleID: "com.apple.Notes",
                              codeKind: nil, ocr: false, box: false, appended: false, format: nil, pixels: 0)
            j.record(e, combo: day + 1, at: first.addingTimeInterval(Double(day) * 86_400))
        }
        let pick = GrabEvent(mode: .color, text: "#ED6E2A", color: RGBAColor(hex: "#ED6E2A"), bundleID: "com.apple.Safari",
                             codeKind: nil, ocr: false, box: false, appended: false, format: nil, pixels: 0)
        j.record(pick, combo: 1, at: first)
        let log = try! XCTUnwrap(Journal(defaults: t.d).months["2026-09"])
        XCTAssertEqual(log.total, 5)
        XCTAssertEqual(log.topApp?.bundleID, "com.apple.Notes")
        XCTAssertEqual(log.longestStreak, 3)
        XCTAssertEqual(log.bestCombo, 6)
        XCTAssertEqual(log.biggestText, 305)
        XCTAssertEqual(log.colors, ["#ED6E2A"])
        XCTAssertEqual(log.busiestHour, 15)
        XCTAssertEqual(log.topKind, .text)
        // October: September's card is announced once.
        let october = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        XCTAssertNil(j.takeReadyMonth(at: october), "fewer than 10 grabs isn't worth a card")
        for i in 0..<5 { j.record(pick, combo: 1, at: first.addingTimeInterval(Double(i) * 60)) }
        XCTAssertEqual(j.takeReadyMonth(at: october), "2026-09")
        XCTAssertNil(j.takeReadyMonth(at: october))
    }
}

final class FunFormatTests: XCTestCase {
    func testReceiptWrapping() {
        let lines = FunFormats.wrap("Everyone's waiting on Gemini 4 Argon, Fable 5.5, or whatever ships next week.\n\nA supercalifragilisticexpialidocious-ish word", width: 32)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 32 })
        XCTAssertEqual(lines.first, "Everyone's waiting on Gemini 4")
        XCTAssertTrue(lines.contains(""), "paragraphs keep their gap")
        XCTAssertEqual(FunFormats.price("Oat milk"), FunFormats.price("Oat milk"), "same item, same price")
        XCTAssertTrue((99...1499).contains(FunFormats.price("Bananas")))
    }

    func testStickerHasAWhiteBorder() throws {
        // A blue disc on transparent: the sticker is bigger, white just outside the disc, clear in the corners.
        let side = 120
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        let sticker = try XCTUnwrap(FunFormats.sticker(ctx.makeImage()!, scale: 2))
        XCTAssertGreaterThan(sticker.width, side + 20)
        let px = try XCTUnwrap(ImageTools.Pixels(sticker))
        let c = sticker.width / 2
        let edge = px.at(c, c - side / 2 - 6)
        XCTAssertGreaterThan(edge.3, 240)
        XCTAssertGreaterThan(min(edge.0, edge.1, edge.2), 240, "white border just outside the subject")
        XCTAssertLessThan(px.at(2, 2).3, 20)
    }

    @MainActor
    func testReceiptAndPhotoRender() throws {
        _ = NSApplication.shared
        let r = try XCTUnwrap(FunFormats.receipt(lines: ["Milk", "Bread"], isList: true, store: "shop.example", cashier: "Snap"))
        XCTAssertGreaterThan(r.pointSize.height, r.pointSize.width)
        let img = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        for film in PolaroidStyle.Film.allCases {
            var style = PolaroidStyle()
            style.film = film
            let p = try XCTUnwrap(Polaroid.make(img, pointSize: CGSize(width: 200, height: 150), caption: "shop.example · Oct 4", style: style), film.title)
            XCTAssertGreaterThan(p.pointSize.height, 150 + 40, "the wide bottom edge")
        }
    }

    func testPolaroidCaptions() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 21, minute: 41))!
        var style = PolaroidStyle()
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        XCTAssertEqual(style.captionText(site: "youtube.com", app: "Safari", title: "A video", at: date), "youtube.com · \(day)")
        style.caption = .place
        XCTAssertEqual(style.captionText(site: "youtube.com", app: "Safari", title: nil, at: date), "youtube.com")
        style.caption = .none
        XCTAssertEqual(style.captionText(site: "youtube.com", app: "Safari", title: nil, at: date), "")
        style.caption = .custom
        style.custom = "{title} on {app}, {year}"
        XCTAssertEqual(style.captionText(site: "youtube.com", app: "Safari", title: "A video", at: date), "A video on Safari, 2026")
        style.custom = "seen at {site}"
        XCTAssertEqual(style.captionText(site: "youtube.com", app: nil, title: nil, at: date), "seen at youtube.com")
    }
}

extension BadgeTests {
    func testCatchUpAwardsWhatCountsAlreadyReach() {
        let t = TestDefaults()
        let b = Badges(defaults: t.d)
        // Pets are counted elsewhere; 25 already reaches Best Friends.
        let new = b.catchUp(pets: 25)
        XCTAssertTrue(new.contains(.bestFriends))
        XCTAssertFalse(new.contains(.nightOwl), "time-of-day badges need a grab at that time")
        XCTAssertTrue(b.catchUp(pets: 25).isEmpty, "only once")
        XCTAssertEqual(Badge.century.unit, "grabs")
    }
}
