import AppKit
import Foundation

/// Runs Grab's heavy pixel work (OCR, barcodes, subject lifting) in a helper process.
///
/// Vision's models need tens of megabytes of memory once loaded, and a process can't
/// unload them. So they live in a short-lived copy of Grab (`Grab --vision-worker`)
/// that starts when you hold ⌥ and exits after a little while idle, and Grab itself
/// stays tiny. If the helper ever fails, the work runs in-process instead.
actor VisionService {
    static let shared = VisionService()

    private var process: Process?
    private var input: FileHandle?
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<(VisionReply, Data), Error>] = [:]
    private var sentAt: [UInt64: Date] = [:]
    private var failures = 0

    enum Failure: Error { case unavailable, worker(String), busy }

    /// When the helper has stopped answering for a while (it's still getting its models
    /// ready), new work isn't stacked on top of it: it comes back empty at once instead.
    static let stalledAfter: TimeInterval = 5

    /// Set while a new build of Grab prepares its text models (see `warmUpIfNewBuild`),
    /// so the HUD can say why text isn't ready yet.
    @MainActor static var preparing = false

    // MARK: API

    /// Start the helper and load the models before they're needed (called on ⌥).
    func prewarm() {
        let fresh = process?.isRunning != true
        guard failures < 3, (try? ensureRunning()) != nil, fresh else { return }
        Task { _ = try? await call(VisionRequest(op: .warm), image: nil) }
    }

    func read(_ cap: Capture, correction: Bool = true, barcodes: Bool = true) async -> TextLayout {
        var req = VisionRequest(op: .read, rect: cap.rect)
        req.correction = correction
        req.barcodes = barcodes
        do {
            let (r, _) = try await call(req, image: cap.image)
            if let l = r.layout { return l }
        } catch Failure.busy {
            return TextLayout()
        } catch {}
        return await TextReader.read(cap, correction: correction, barcodes: barcodes)
    }

    func barcodes(_ cap: Capture) async -> [Barcode] {
        do {
            let (r, _) = try await call(VisionRequest(op: .barcodes, rect: cap.rect), image: cap.image)
            if let c = r.codes { return c }
        } catch Failure.busy {
            return []
        } catch {}
        return BarcodeScanner.detect(in: cap)
    }

    func recognize(_ cap: Capture, accurate: Bool) async -> [OCRLine] {
        var req = VisionRequest(op: .recognize, rect: cap.rect)
        req.accurate = accurate
        do {
            let (r, _) = try await call(req, image: cap.image)
            if let l = r.lines { return l }
        } catch Failure.busy {
            return []
        } catch {}
        return VisionEngine.recognize(cap, accurate: accurate, correction: false)
    }

    /// The first time a new build of Grab reads text (after an update or a reinstall),
    /// macOS prepares the recognition models for it, which can take a minute. Do that
    /// right after launch, in the background, instead of when you first hold ⌥.
    func warmUpIfNewBuild() async {
        guard let key = Self.buildKey(), UserDefaults.standard.string(forKey: "visionWarmBuild") != key else { return }
        await MainActor.run { Self.preparing = true }
        defer { Task { @MainActor in Self.preparing = false } }
        guard (try? ensureRunning()) != nil else { return }
        if (try? await send(VisionRequest(op: .warm), image: nil)) != nil {
            UserDefaults.standard.set(key, forKey: "visionWarmBuild")
        }
    }

    /// This build's code signature hash: it changes with every build and update.
    nonisolated static func buildKey() -> String? {
        var me: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func subject(of image: CGImage) async -> CGImage? {
        if let (r, data) = try? await call(VisionRequest(op: .subject), image: image) {
            guard let w = r.width, let h = r.height, let bpr = r.bytesPerRow, !data.isEmpty else { return nil }
            return PixelBuffer.image(data, width: w, height: h, bytesPerRow: bpr)
        }
        return ImageTools.subject(of: image)
    }

    // MARK: Plumbing

    private func call(_ request: VisionRequest, image: CGImage?) async throws -> (VisionReply, Data) {
        // After repeated trouble, stop trying for this run and work in-process.
        guard failures < 3 else { throw Failure.unavailable }
        for attempt in 0..<2 {
            do {
                return try await send(request, image: image)
            } catch Failure.worker(let why) {
                throw Failure.worker(why)
            } catch Failure.busy {
                throw Failure.busy
            } catch {
                // The helper exited (idle timeout racing a new request): one fresh try.
                if attempt == 1 { failures += 1; throw error }
            }
        }
        throw Failure.unavailable
    }

    private func send(_ request: VisionRequest, image: CGImage?) async throws -> (VisionReply, Data) {
        // A helper still preparing its models answers nothing for a while: don't pile on.
        if request.op != .warm, request.op != .subject, let oldest = sentAt.values.min(),
           Date().timeIntervalSince(oldest) > Self.stalledAfter {
            throw Failure.busy
        }
        let handle = try ensureRunning()
        var req = request
        req.id = nextID
        nextID += 1
        var payload = Data()
        // Text and codes read just as well in grayscale: a quarter of the bytes.
        let gray = request.op != .subject
        if let image, let (data, w, h, bpr) = PixelBuffer.pixels(of: image, gray: gray) {
            payload = data
            req.width = w
            req.height = h
            req.bytesPerRow = bpr
            req.gray = gray
        }
        let frame = try Frame.encode(req, payload: payload)
        return try await withCheckedThrowingContinuation { c in
            pending[req.id] = c
            sentAt[req.id] = Date()
            do {
                try handle.write(contentsOf: frame)
            } catch {
                pending[req.id] = nil
                sentAt[req.id] = nil
                c.resume(throwing: error)
            }
        }
    }

    private func ensureRunning() throws -> FileHandle {
        if let p = process, p.isRunning, let input { return input }
        guard let exe = Bundle.main.executableURL else { throw Failure.unavailable }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--vision-worker"]
        let toWorker = Pipe(), fromWorker = Pipe()
        p.standardInput = toWorker
        p.standardOutput = fromWorker
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        // The service lives as long as the app, so these hold it strongly: a weak reference
        // read from the reader thread while a reply was being delivered could crash.
        let service = self
        p.terminationHandler = { proc in
            Task { await service.exited(proc) }
        }
        try p.run()
        process = p
        input = toWorker.fileHandleForWriting
        let output = fromWorker.fileHandleForReading
        // Replies are read on their own thread and handed back to the actor.
        let reader = Thread {
            while let (reply, data) = Frame.read(VisionReply.self, from: output) {
                Task { await service.deliver(reply, data) }
            }
        }
        reader.name = "Grab.VisionReplies"
        reader.qualityOfService = .userInitiated
        reader.start()
        return toWorker.fileHandleForWriting
    }

    private func deliver(_ reply: VisionReply, _ data: Data) {
        sentAt[reply.id] = nil
        guard let c = pending.removeValue(forKey: reply.id) else { return }
        if let error = reply.error { c.resume(throwing: Failure.worker(error)) } else { c.resume(returning: (reply, data)) }
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        input = nil
        let waiting = pending
        pending.removeAll()
        sentAt.removeAll()
        for c in waiting.values { c.resume(throwing: Failure.unavailable) }
    }
}

// MARK: - Wire format

enum VisionOp: String, Codable { case warm, read, barcodes, recognize, subject }

struct VisionRequest: Codable {
    var id: UInt64 = 0
    var op: VisionOp
    var rect: CGRect = .zero
    var width = 0
    var height = 0
    var bytesPerRow = 0
    var gray = false
    var correction = true
    var barcodes = true
    var accurate = true
}

struct VisionReply: Codable {
    var id: UInt64
    var error: String?
    var layout: TextLayout?
    var codes: [Barcode]?
    var lines: [OCRLine]?
    var width: Int?
    var height: Int?
    var bytesPerRow: Int?
}

/// [UInt32 header length][JSON header][UInt32 payload length][payload]
enum Frame {
    static func encode<T: Encodable>(_ header: T, payload: Data) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var out = Data(capacity: 8 + json.count + payload.count)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(json)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Blocks until a whole frame arrives; nil at end of stream.
    static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) -> (T, Data)? {
        guard let n = readLength(handle), let json = readExactly(handle, n),
              let header = try? JSONDecoder().decode(T.self, from: json),
              let m = readLength(handle), let payload = readExactly(handle, m) else { return nil }
        return (header, payload)
    }

    private static func readLength(_ h: FileHandle) -> Int? {
        guard let d = readExactly(h, 4) else { return nil }
        return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    }

    private static func readExactly(_ h: FileHandle, _ n: Int) -> Data? {
        guard n > 0 else { return Data() }
        var out = Data(capacity: n)
        while out.count < n {
            guard let chunk = try? h.read(upToCount: n - out.count), !chunk.isEmpty else { return nil }
            out.append(chunk)
        }
        return out
    }
}

/// Raw BGRA pixels in and out of CGImages.
enum PixelBuffer {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static let graySpace = CGColorSpaceCreateDeviceGray()

    static func pixels(of image: CGImage, gray: Bool = false) -> (Data, Int, Int, Int)? {
        if gray, let direct = grayDirect(image) { return direct }
        let w = image.width, h = image.height, bpr = gray ? w : w * 4
        guard w > 0, h > 0 else { return nil }
        var data = Data(count: bpr * h)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: gray ? graySpace : space,
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h, bpr) : nil
    }

    /// Grayscale straight from a capture's own bytes. Drawing the capture instead
    /// makes CoreGraphics keep a decoded copy alive alongside it (megabytes each).
    private static func grayDirect(_ image: CGImage) -> (Data, Int, Int, Int)? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, let cf = image.dataProvider?.data else { return nil }
        let w = image.width, h = image.height, src = image.bytesPerRow
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alpha = image.alphaInfo
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        // Byte offsets of red and blue within each pixel.
        let (r, b): (Int, Int) = little ? (alphaFirst ? (2, 0) : (3, 1)) : (alphaFirst ? (1, 3) : (0, 2))
        let g = 1 + (little ? (alphaFirst ? 0 : 1) : (alphaFirst ? 1 : 0))
        guard CFDataGetLength(cf) >= src * h, let base = CFDataGetBytePtr(cf) else { return nil }
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { dst in
            let d = dst.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<h {
                let row = base + y * src
                let o = d + y * w
                for x in 0..<w {
                    let p = row + x * 4
                    o[x] = UInt8((Int(p[r]) * 77 + Int(p[g]) * 150 + Int(p[b]) * 29) >> 8)
                }
            }
        }
        return (out, w, h, w)
    }

    static func image(_ data: Data, width: Int, height: Int, bytesPerRow: Int, gray: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: gray ? 8 : 32, bytesPerRow: bytesPerRow,
                       space: gray ? graySpace : space,
                       bitmapInfo: CGBitmapInfo(rawValue: gray ? CGImageAlphaInfo.none.rawValue : info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - The helper process

/// `Grab --vision-worker`: answers requests on stdin until it's been idle a while.
enum VisionWorker {
    static let idleExit: TimeInterval = 25

    static func run() -> Never {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        let writeLock = NSLock()
        let state = NSLock()
        var inFlight = 0
        var lastActivity = Date()

        func reply(_ r: VisionReply, _ payload: Data = Data()) {
            guard let frame = try? Frame.encode(r, payload: payload) else { return }
            writeLock.lock()
            try? output.write(contentsOf: frame)
            writeLock.unlock()
        }

        // Leave when idle, so the models' memory goes back to the system.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            state.lock()
            let idle = inFlight == 0 && Date().timeIntervalSince(lastActivity) > idleExit
            state.unlock()
            if idle { exit(0) }
        }
        timer.resume()

        while let (req, payload) = Frame.read(VisionRequest.self, from: input) {
            state.lock()
            inFlight += 1
            lastActivity = Date()
            state.unlock()
            let finished = {
                state.lock()
                inFlight -= 1
                lastActivity = Date()
                state.unlock()
            }
            Task.detached(priority: .userInitiated) {
                let r = await handle(req, payload)
                reply(r.0, r.1)
                finished()
            }
        }
        // Grab went away.
        exit(0)
    }

    private static func handle(_ req: VisionRequest, _ payload: Data) async -> (VisionReply, Data) {
        var r = VisionReply(id: req.id)
        if req.op == .warm {
            await TextReader.warmUp()
            return (r, Data())
        }
        guard let image = PixelBuffer.image(payload, width: req.width, height: req.height, bytesPerRow: req.bytesPerRow, gray: req.gray) else {
            r.error = "bad image"
            return (r, Data())
        }
        let cap = Capture(image: image, rect: req.rect)
        switch req.op {
        case .read:
            r.layout = await TextReader.read(cap, correction: req.correction, barcodes: req.barcodes)
        case .barcodes:
            r.codes = BarcodeScanner.detect(in: cap)
        case .recognize:
            r.lines = VisionEngine.recognize(cap, accurate: req.accurate, correction: false)
        case .subject:
            if let cut = ImageTools.subject(of: image), let (data, w, h, bpr) = PixelBuffer.pixels(of: cut) {
                r.width = w
                r.height = h
                r.bytesPerRow = bpr
                return (r, data)
            }
        case .warm:
            break
        }
        return (r, Data())
    }
}
