import AppKit
import Observation

enum Clipboard {
    /// What was on the clipboard before Grab's last write, for ⌥Z.
    private static var snapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private static var ourChangeCount = -1
    private static var provider: AdaptiveText?
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let snapshotTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .URL, .fileURL, .png, .tiff, .rtf, .html, .pdf, .color, .tabularText,
        NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.url-name"),
    ]

    /// Adds text to what's already on the clipboard, separated by a newline.
    /// Returns false when the payload can't be appended (images replace instead).
    @discardableResult
    static func append(_ payload: Payload) -> Bool {
        let addition: String
        switch payload {
        case .text(let s), .code(let s), .color(_, let s): addition = s
        case .link(let u): addition = u.absoluteString
        case .file(let u): addition = u.path
        case .image:
            write(payload)
            return false
        }
        let existing = NSPasteboard.general.string(forType: .string) ?? ""
        write(.text(existing.isEmpty ? addition : existing + "\n" + addition))
        return true
    }

    /// - Parameters:
    ///   - secret: hide from clipboard managers and clear after a minute.
    ///   - adaptive: code that adapts to where it's pasted (see `AdaptiveText`).
    static func write(_ payload: Payload, secret: Bool = false, adaptive: (language: String, enabled: Bool)? = nil) {
        let pb = NSPasteboard.general
        takeSnapshot()
        pb.clearContents()
        let item = NSPasteboardItem()
        provider = nil
        switch payload {
        case .text(let s), .code(let s):
            if let a = adaptive, a.enabled, !secret {
                let p = AdaptiveText(text: s, language: a.language)
                provider = p
                item.setDataProvider(p, forTypes: [.string])
            } else {
                item.setString(s, forType: .string)
            }
        case .link(let url):
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        case .file(let url):
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
        case .image(let cg, let pointSize):
            let rep = NSBitmapImageRep(cgImage: cg)
            // Keep Retina captures at their on-screen size when pasted.
            rep.size = pointSize
            if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        case .color(_, let formatted):
            item.setString(formatted, forType: .string)
        }
        if secret { item.setString("", forType: concealedType) }
        pb.writeObjects([item])
        ourChangeCount = pb.changeCount
        if secret {
            let count = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
        }
    }

    /// Copies what's on the clipboard now, unless it's huge.
    private static func takeSnapshot() {
        let pb = NSPasteboard.general
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        var total = 0
        for item in pb.pasteboardItems ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for t in item.types {
                // Common formats only: others can be huge or generated on demand by their app.
                guard Self.snapshotTypes.contains(t) || t.rawValue.hasPrefix("public.utf8") else { continue }
                guard let d = item.data(forType: t) else { continue }
                total += d.count
                if total > 40_000_000 { snapshot = nil; return }
                entry.append((t, d))
            }
            items.append(entry)
        }
        snapshot = items
    }

    /// Puts back what was on the clipboard before Grab's last copy.
    static func undo() -> Bool {
        let pb = NSPasteboard.general
        guard let snap = snapshot, pb.changeCount == ourChangeCount else { return false }
        pb.clearContents()
        let items = snap.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in entry { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        snapshot = nil
        ourChangeCount = -1
        return true
    }

    static var canUndo: Bool { snapshot != nil && NSPasteboard.general.changeCount == ourChangeCount }
}

/// Code whose clipboard text is decided at paste time: prompts are stripped when
/// pasting into a terminal, and chat or notes apps get a Markdown code fence.
final class AdaptiveText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    let language: String

    init(text: String, language: String) {
        self.text = text
        self.language = language
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        item.setString(Self.adapt(text, language: language, for: target), forType: type)
    }

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "io.alacritty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "org.tabby",
    ]
    static let fenceApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams", "md.obsidian",
        "notion.id", "net.shinyfrog.bear", "abnerworks.Typora", "pro.writer.mac", "com.linear", "ru.keepcoder.Telegram",
    ]

    static func adapt(_ text: String, language: String, for bundleID: String) -> String {
        if terminals.contains(bundleID) {
            return stripPrompts(text)
        }
        if fenceApps.contains(bundleID) {
            if !text.contains("\n") { return text.contains("`") ? "`` \(text) ``" : "`\(text)`" }
            return Formats.markdownFence(text, language: language)
        }
        return text
    }

    /// "$ npm test" lines keep only the command; output lines are dropped.
    static func stripPrompts(_ text: String) -> String {
        let a = CodeAnalysis(text: text, language: .shell, terminal: true)
        let lines = text.components(separatedBy: "\n")
        guard lines.count == a.lineCount else { return text }
        var commands: [String] = []
        for (i, line) in lines.enumerated() {
            if let p = a.promptLength(i) { commands.append(String((line as NSString).substring(from: min(p, (line as NSString).length)))) }
        }
        return commands.isEmpty ? text : commands.joined(separator: "\n")
    }
}

/// Recent grabs. In memory only, unless you turn on Keep History (then encrypted on
/// disk, see `HistoryVault`); secrets are never saved.
@Observable
final class History {
    static let shared = History()

    struct Item: Identifiable {
        let id: UUID
        let mode: GrabMode
        let title: String
        let date: Date
        let thumbnail: NSImage?
        let color: RGBAColor?
        /// App it came from, and the page or window title.
        var appName: String? = nil
        var bundleID: String? = nil
        var source: String? = nil
        var sourceURL: URL? = nil
        var isSecret = false
        /// What a copy-again puts back. Images are kept compressed (a screenshot is
        /// tens of megabytes uncompressed) and decoded only when they're copied again.
        private let stored: Payload?
        private let image: CompressedImage?

        init(mode: GrabMode, payload: Payload, title: String, thumbnail: NSImage?, color: RGBAColor?) {
            id = UUID()
            date = Date()
            self.mode = mode
            self.title = title
            self.thumbnail = thumbnail
            self.color = color
            if case .image(let img, let size) = payload {
                stored = nil
                image = CompressedImage(img, pointSize: size)
            } else {
                stored = payload
                image = nil
            }
        }

        /// A grab saved by Keep History.
        init?(record r: HistoryVault.Record) {
            id = r.id
            date = r.date
            mode = GrabMode(rawValue: r.mode) ?? .text
            title = r.title
            thumbnail = r.thumbnail.flatMap { NSImage(data: $0) }
            color = r.color.flatMap { $0.count == 4 ? RGBAColor(r: $0[0], g: $0[1], b: $0[2], a: $0[3]) : nil }
            appName = r.appName
            bundleID = r.bundleID
            source = r.source
            sourceURL = r.sourceURL.flatMap(URL.init(string:))
            guard let (payload, picture) = Self.restore(r, color: color) else { return nil }
            stored = payload
            image = picture
        }

        private static func restore(_ r: HistoryVault.Record, color: RGBAColor?) -> (Payload?, CompressedImage?)? {
            switch r.kind {
            case "text": return (.text(r.text ?? ""), nil)
            case "code": return (.code(r.text ?? ""), nil)
            case "link": return r.text.flatMap(URL.init(string:)).map { (.link($0), nil) }
            case "file": return r.text.map { (.file(URL(fileURLWithPath: $0)), nil) }
            case "color": return color.map { (.color($0, r.text ?? $0.hex), nil) }
            case "image":
                guard let png = r.image else { return nil }
                let size = r.pointSize.flatMap { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil } ?? .zero
                return (nil, CompressedImage(png: png, pointSize: size))
            default: return nil
            }
        }

        /// What Keep History writes. Never for secrets.
        func record() -> HistoryVault.Record? {
            guard !isSecret else { return nil }
            var r = HistoryVault.Record(id: id, date: date, mode: mode.rawValue, title: title, kind: "text",
                                        appName: appName, bundleID: bundleID, source: source, sourceURL: sourceURL?.absoluteString)
            switch stored {
            case .text(let t): r.text = t
            case .code(let t): r.kind = "code"; r.text = t
            case .link(let u): r.kind = "link"; r.text = u.absoluteString
            case .file(let u): r.kind = "file"; r.text = u.path
            case .color(let c, let f): r.kind = "color"; r.text = f; r.color = [c.r, c.g, c.b, c.a]
            case .image, .none:
                guard let image, let png = image.pngData else { return nil }
                r.kind = "image"
                r.image = png
                r.pointSize = [image.pointSize.width, image.pointSize.height]
            }
            if let t = thumbnail, let cg = t.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                r.thumbnail = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            return r
        }

        var payload: Payload {
            if let stored { return stored }
            if let image, let img = image.cgImage { return .image(img, pointSize: image.pointSize) }
            return .text(title)
        }

        /// The text this grab holds, for search and previews (not for images).
        var text: String? {
            switch stored {
            case .text(let t), .code(let t): t
            case .link(let u): u.absoluteString
            case .file(let u): u.path
            case .color(_, let f): f
            default: nil
            }
        }

        var kind: Kind {
            switch stored {
            case .link: .links
            case .file: .files
            case .color: .colors
            case .code: .codes
            case .none: .images
            case .text: mode == .qr ? .codes : .text
            case .image: .images
            }
        }

        /// Everything searchable about the item.
        var searchText: String {
            var parts = [title, mode.title, appName ?? "", source ?? "", sourceURL?.absoluteString ?? ""]
            if !isSecret, let t = text { parts.append(String(t.prefix(4_000))) }
            return parts.joined(separator: " ")
        }
    }

    /// Filters in the history window.
    enum Kind: String, CaseIterable, Identifiable {
        case text, links, images, colors, files, codes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: "Text"
            case .links: "Links"
            case .images: "Images"
            case .colors: "Colors"
            case .files: "Files"
            case .codes: "QR"
            }
        }
        var symbol: String {
            switch self {
            case .text: "text.quote"
            case .links: "link"
            case .images: "photo"
            case .colors: "paintpalette"
            case .files: "doc"
            case .codes: "qrcode"
            }
        }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var vault: HistoryVault?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var appendsSinceRewrite = 0

    func add(_ item: Item) {
        ensureLoaded()
        items.insert(item, at: 0)
        let limit = max(1, Settings.shared.historyLimit)
        if items.count > limit { items.removeLast(items.count - limit) }
        guard Settings.shared.keepHistory, !item.isSecret, let vault = openVault(create: false) else { return }
        appendsSinceRewrite += 1
        if appendsSinceRewrite > limit {
            // The file only grows between rewrites; trim it back to what's shown.
            saveAll()
        } else {
            DispatchQueue.global(qos: .utility).async { if let r = item.record() { vault.append(r) } }
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if Settings.shared.keepHistory { saveAll() }
    }

    func clear() {
        items.removeAll()
        vault?.erase()
    }

    // MARK: Keep History

    /// Saved grabs are read on first use (the menu, the history window, the next grab),
    /// not at launch, so Grab starts as light as ever.
    func ensureLoaded() {
        guard Settings.shared.keepHistory, !loaded else { return }
        loaded = true
        guard let vault = openVault(create: false) else { return }
        let all = vault.load()
        let cutoff = Date().addingTimeInterval(-Double(max(1, Settings.shared.keepHistoryDays)) * 86_400)
        let limit = max(1, Settings.shared.historyLimit)
        var kept = all.filter { $0.date >= cutoff }
        if kept.count > limit { kept = Array(kept.suffix(limit)) }
        if kept.count != all.count { vault.rewrite(kept) }
        let known = Set(items.map(\.id))
        items += kept.reversed().compactMap(Item.init(record:)).filter { !known.contains($0.id) }
        items.sort { $0.date > $1.date }
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    /// Turning Keep History on saves what's here now; turning it off deletes the file and its key.
    func setKeepHistory(_ on: Bool) {
        if on {
            guard openVault(create: true) != nil else { return }
            loaded = true
            saveAll()
        } else {
            vault?.erase()
            HistoryVault.Keychain.delete()
            vault = nil
            loaded = false
        }
    }

    private func saveAll() {
        guard let vault = openVault(create: false) else { return }
        appendsSinceRewrite = 0
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            vault.rewrite(snapshot.reversed().compactMap { $0.record() })
        }
    }

    #if DEBUG
    /// Keep History against a throwaway file and key, never the keychain (`vaulttest:<dir>`).
    func debugUseVault(_ v: HistoryVault) {
        vault = v
        loaded = false
    }

    /// Forgets what's in memory and reads the saved history back, like a fresh launch.
    func debugReload() {
        items.removeAll()
        loaded = false
        ensureLoaded()
    }
    #endif

    private func openVault(create: Bool) -> HistoryVault? {
        if let vault { return vault }
        guard let key = HistoryVault.Keychain.key(create: create) else { return nil }
        vault = HistoryVault(url: HistoryVault.defaultURL, key: key)
        return vault
    }

    /// Items grouped by the app they came from, most recently used app first.
    func byApp(_ list: [Item]) -> [(app: String, bundleID: String?, items: [Item])] {
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for i in list {
            let key = i.appName ?? "Other"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }
        return order.map { ($0, groups[$0]?.first?.bundleID, groups[$0] ?? []) }
    }
}

/// An image kept as PNG: compressed in the background right after it's added, after
/// which the full bitmap is let go.
final class CompressedImage: @unchecked Sendable {
    let pointSize: CGSize
    private let lock = NSLock()
    private var bitmap: CGImage?
    private var png: Data?

    /// Restored from Keep History: stays compressed until it's copied again.
    init(png: Data, pointSize: CGSize) {
        self.pointSize = pointSize
        self.png = png
    }

    /// The PNG, compressing now if the background pass hasn't finished.
    var pngData: Data? {
        lock.lock()
        defer { lock.unlock() }
        if let png { return png }
        guard let bitmap else { return nil }
        return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
    }

    init(_ image: CGImage, pointSize: CGSize) {
        self.pointSize = pointSize
        bitmap = image
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            lock.lock()
            png = data
            if data != nil { bitmap = nil }
            lock.unlock()
        }
    }

    var cgImage: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let bitmap { return bitmap }
        guard let png, let rep = NSBitmapImageRep(data: png) else { return nil }
        return rep.cgImage
    }
}

/// Grabs collected with ⌥⇧C, shown in a floating shelf you can reorder.
@Observable
final class Shelf {
    static let shared = Shelf()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let payload: Payload
        let title: String
        let mode: GrabMode
        let thumbnail: NSImage?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }

        var text: String? {
            switch payload {
            case .text(let s), .code(let s), .color(_, let s): s
            case .link(let u): u.absoluteString
            case .file(let u): u.path
            case .image: nil
            }
        }
    }

    var items: [Item] = []
    /// ⌥V pastes the items one at a time; this is the next one.
    var next = 0

    func add(_ item: Item) { items.append(item) }

    func remove(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }), i < next { next -= 1 }
        items.removeAll { $0.id == id }
        syncClipboard()
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        next = 0
        syncClipboard()
    }

    func clear() {
        items.removeAll()
        next = 0
    }

    /// The item ⌥V should paste now, moving the queue along. Starts over after the last.
    func takeNext() -> (item: Item, index: Int)? {
        guard !items.isEmpty else { return nil }
        if next >= items.count { next = 0 }
        let i = next
        next += 1
        return (items[i], i)
    }

    /// The clipboard always holds the shelf, in order: text joined by newlines,
    /// images as extra items.
    func syncClipboard() {
        guard !items.isEmpty else { return }
        let texts = items.compactMap(\.text)
        let images = items.compactMap { i -> Payload? in if case .image = i.payload { return i.payload }; return nil }
        if images.isEmpty || !texts.isEmpty {
            Clipboard.write(.text(texts.joined(separator: "\n")))
        } else if let first = images.first {
            Clipboard.write(first)
        }
    }
}
