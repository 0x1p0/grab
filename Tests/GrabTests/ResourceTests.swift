import XCTest
@testable import Grab

final class ResourceTests: XCTestCase {
    func testHistoryGroupsByAppMostRecentFirst() {
        let h = History()
        func item(_ text: String, _ app: String) -> History.Item {
            var i = History.Item(mode: .text, payload: .text(text), title: text, thumbnail: nil, color: nil)
            i.appName = app
            return i
        }
        let list = [item("c", "Safari"), item("b", "Xcode"), item("a", "Safari")]
        let groups = h.byApp(list)
        XCTAssertEqual(groups.map(\.app), ["Safari", "Xcode"])
        XCTAssertEqual(groups[0].items.map(\.title), ["c", "a"])
        XCTAssertEqual(History.Item(mode: .link, payload: .link(URL(string: "https://x.com")!), title: "x", thumbnail: nil, color: nil).kind, .links)
        XCTAssertEqual(History.Item(mode: .qr, payload: .code("hi"), title: "hi", thumbnail: nil, color: nil).kind, .codes)
    }

    func testImagesAreKeptCompressedAndComeBack() {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: PixelBuffer.space, bitmapInfo: PixelBuffer.info)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let img = ctx.makeImage()!
        let item = History.Item(mode: .image, payload: .image(img, pointSize: CGSize(width: 32, height: 16)), title: "img", thumbnail: nil, color: nil)
        let done = expectation(description: "compressed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        guard case .image(let back, let size) = item.payload else { return XCTFail("not an image") }
        XCTAssertEqual(back.width, 64)
        XCTAssertEqual(size, CGSize(width: 32, height: 16))
        XCTAssertEqual(item.kind, .images)
    }

    func testFramesRoundTripThroughAPipe() throws {
        let pipe = Pipe()
        var req = VisionRequest(op: .read, rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        req.id = 42
        req.gray = true
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        try pipe.fileHandleForWriting.write(contentsOf: Frame.encode(req, payload: payload))
        let (back, data) = try XCTUnwrap(Frame.read(VisionRequest.self, from: pipe.fileHandleForReading))
        XCTAssertEqual(back.id, 42)
        XCTAssertEqual(back.op, .read)
        XCTAssertTrue(back.gray)
        XCTAssertEqual(back.rect, CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(data, payload)
    }

    func testGrayscaleConversion() throws {
        let ctx = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16, space: PixelBuffer.space, bitmapInfo: PixelBuffer.info)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        let img = try XCTUnwrap(ctx.makeImage())
        let (data, w, h, bpr) = try XCTUnwrap(PixelBuffer.pixels(of: img, gray: true))
        XCTAssertEqual([w, h, bpr], [4, 2, 4])
        XCTAssertGreaterThan(data[0], 240)
        XCTAssertLessThan(data[3], 15)
        let back = try XCTUnwrap(PixelBuffer.image(data, width: w, height: h, bytesPerRow: bpr, gray: true))
        XCTAssertEqual(back.width, 4)
    }
}
