import AppKit
import Quartz
import SwiftUI
import Translation

/// A floating panel that stays above other windows without activating Grab: pins,
/// Ask, the shelf and history all live in one of these.
final class FloatingPanel: NSPanel {
    init(size: NSSize, title: String, resizable: Bool = true) {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }

    func host<V: View>(_ view: V) {
        let h = NSHostingView(rootView: view)
        h.sizingOptions = []
        contentView = h
    }

    /// Places the panel next to a point in global top-left coordinates, kept on screen.
    func place(near axPoint: CGPoint, offset: CGFloat = 18) {
        let cocoa = ScreenSpace.toAX(CGRect(origin: axPoint, size: .zero)).origin
        let screen = NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: cocoa.x + offset, y: cocoa.y - frame.height - offset)
        if origin.x + frame.width > visible.maxX - 8 { origin.x = cocoa.x - frame.width - offset }
        if origin.y < visible.minY + 8 { origin.y = cocoa.y + offset }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }
}

/// Opens and tracks Grab's panels.
@MainActor
final class Panels {
    static let shared = Panels()
    private var open: [NSPanel] = []
    private var shelfPanel: FloatingPanel?
    private var historyPanel: FloatingPanel?

    private func track(_ p: NSPanel) {
        open.append(p)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.open.removeAll { $0 === (note.object as? NSPanel) }
            }
        }
    }

    // MARK: Pins

    enum PinContent {
        case text(String, mono: Bool)
        case image(CGImage, size: CGSize)
    }

    func pin(_ content: PinContent, near point: CGPoint) {
        let size: NSSize
        switch content {
        case .text(let t, let mono):
            let lines = t.components(separatedBy: "\n")
            let longest = lines.map(\.count).max() ?? 20
            let width = min(520, max(220, CGFloat(longest) * (mono ? 7.4 : 6.8) + 40))
            let height = min(460, max(80, CGFloat(lines.count) * (mono ? 16 : 18) + 54))
            size = NSSize(width: width, height: height)
        case .image(_, let s):
            let k = min(1, 480 / max(s.width, s.height, 1))
            size = NSSize(width: max(120, s.width * k), height: max(80, s.height * k))
        }
        let p = FloatingPanel(size: size, title: "Pinned")
        if case .image(_, let s) = content, s.width > 0, s.height > 0 { p.contentAspectRatio = s }
        p.host(PinView(content: content))
        p.place(near: point)
        p.orderFrontRegardless()
        track(p)
    }

    // MARK: Ask

    func ask(_ text: String, task: AssistTask, near point: CGPoint) {
        let p = FloatingPanel(size: NSSize(width: 420, height: 340), title: "Ask Grab")
        p.minSize = NSSize(width: 320, height: 220)
        p.host(AskView(source: text, initial: task))
        p.place(near: point)
        p.orderFrontRegardless()
        p.makeKey()
        track(p)
    }

    // MARK: Shelf

    func showShelf() {
        if shelfPanel == nil {
            let p = FloatingPanel(size: NSSize(width: 300, height: 320), title: "Shelf")
            p.minSize = NSSize(width: 240, height: 160)
            p.host(ShelfView())
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: v.maxX - 320, y: v.minY + 20))
            }
            shelfPanel = p
        }
        shelfPanel?.orderFrontRegardless()
    }

    func hideShelf() {
        shelfPanel?.orderOut(nil)
    }

    // MARK: History

    func showHistory() {
        if historyPanel == nil {
            let p = FloatingPanel(size: NSSize(width: 420, height: 480), title: "Grab History")
            p.minSize = NSSize(width: 320, height: 240)
            p.host(HistoryView(close: { [weak p] in p?.close() }))
            p.center()
            historyPanel = p
        }
        NSApp.activate()
        historyPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: Quick Look

    func quickLook(_ urls: [URL]) {
        QuickLook.shared.show(urls)
    }
}

// MARK: - Quick Look

/// Quick Look's panel only takes a data source from a controller in the responder
/// chain; `AppDelegate` is that controller and hands over to this.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

// MARK: - Shared bits

/// The same glass as the HUD, which (unlike a material) keeps its look when the panel isn't key.
private struct PanelBackground: View {
    var body: some View {
        HUDBackground(cornerRadius: 0).ignoresSafeArea()
    }
}

private struct CopyButton: View {
    let action: () -> Void
    @State private var done = false

    var body: some View {
        Button {
            action()
            Sound.shared.play(.copy)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { done = false } }
        } label: {
            Label(done ? "Copied" : "Copy", systemImage: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11.5, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .keyboardShortcut("c", modifiers: .command)
    }
}

// MARK: - Pin

private struct PinView: View {
    let content: Panels.PinContent
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch content {
            case .text(let t, let mono):
                ScrollView {
                    Text(t)
                        .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 30)
                        .padding(.bottom, 14)
                }
                .background(PanelBackground())
            case .image(let img, _):
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
            }
            if hovering {
                CopyButton {
                    switch content {
                    case .text(let t, _): Clipboard.write(.text(t))
                    case .image(let img, let s): Clipboard.write(.image(img, pointSize: s))
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .ignoresSafeArea()
    }
}

// MARK: - Ask

private struct AskView: View {
    let source: String
    @State private var task: AssistTask
    @State private var result = ""
    @State private var error: String?
    @State private var running = false
    @State private var question = ""
    @State private var runID = 0
    @State private var copied = false

    init(source: String, initial: AssistTask) {
        self.source = source
        _task = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source.oneLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 22)

            HStack(spacing: 4) {
                ForEach(AssistTask.allCases) { t in
                    Button {
                        task = t
                        question = ""
                        start()
                    } label: {
                        Label(t.title, systemImage: t.symbol)
                            .font(.system(size: 11, weight: t == task ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(t == task ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Color.primary.opacity(0.06))))
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                if running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(task == .translate ? "Translating…" : "Thinking on-device…").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(12)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(12)
                } else {
                    ScrollView {
                        Text(result)
                            .font(task == .extract ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField("Ask a question about this…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { start() }
                CopyButton { Clipboard.write(.text(result)) }
                    .disabled(result.isEmpty || running)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .background(PanelBackground())
        .background {
            if task == .translate, question.isEmpty, #available(macOS 15.0, *) {
                TranslateRunner(text: source, trigger: runID) { r in
                    running = false
                    switch r {
                    case .success(let t):
                        result = t
                        Clipboard.write(.text(t))
                    case .failure(let e):
                        error = "Couldn't translate: \(e.localizedDescription)"
                    }
                }
            }
        }
        .onAppear { start() }
    }

    private func start() {
        error = nil
        result = ""
        running = true
        runID += 1
        let q = question.trimmingCharacters(in: .whitespaces).nonBlank
        if task == .translate && q == nil {
            if #unavailable(macOS 15.0) {
                running = false
                error = "Translation needs macOS 15 or later."
            }
            return
        }
        let id = runID
        let t = task
        let text = source
        Task { @MainActor in
            do {
                let out = try await Assistant.run(t, text: text, question: q)
                guard id == runID else { return }
                result = out
                running = false
                // Transformations replace the clipboard; explanations don't.
                if q == nil, t == .fix || t == .extract { Clipboard.write(.text(out)) }
            } catch {
                guard id == runID else { return }
                running = false
                self.error = (error as? GrabError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

@available(macOS 15.0, *)
private struct TranslateRunner: View {
    let text: String
    let trigger: Int
    let done: (Result<String, Error>) -> Void
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .translationTask(config) { session in
                do {
                    let r = try await session.translate(text)
                    await MainActor.run { done(.success(r.targetText)) }
                } catch {
                    await MainActor.run { done(.failure(error)) }
                }
            }
            .onChange(of: trigger, initial: true) { _, _ in
                if config == nil { config = .init() } else { config?.invalidate() }
            }
    }
}

// MARK: - Shelf

private struct ShelfView: View {
    private let shelf = Shelf.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shelf").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(shelf.items.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                Button("Clear") {
                    shelf.clear()
                    Panels.shared.hideShelf()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.top, 24)
            .padding(.horizontal, 12)

            List {
                ForEach(shelf.items) { item in
                    HStack(spacing: 8) {
                        if let t = item.thumbnail {
                            Image(nsImage: t).resizable().aspectRatio(contentMode: .fit).frame(width: 26, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Image(systemName: item.mode.symbol).font(.system(size: 11)).frame(width: 26).foregroundStyle(.secondary)
                        }
                        Text(item.title.oneLine).font(.system(size: 12)).lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            shelf.remove(item.id)
                            if shelf.items.isEmpty { Panels.shared.hideShelf() }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { shelf.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            HStack {
                Text("Drag to reorder · ⌥⇧C adds").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                CopyButton { shelf.syncClipboard() }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(PanelBackground())
        .ignoresSafeArea()
    }
}

// MARK: - History

private struct HistoryView: View {
    let close: () -> Void
    private let history = History.shared
    @State private var query = ""
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool

    private var filtered: [History.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.items }
        let terms = q.split(separator: " ")
        return history.items.filter { item in
            let hay = item.searchText.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search grabs", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { copy(first) } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            .padding(.top, 28)
            .padding(.horizontal, 12)

            if filtered.isEmpty {
                Spacer()
                Text(history.items.isEmpty ? "Nothing grabbed yet" : "No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { item in
                    Button { copy(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            Text("Kept in memory only · click or ⏎ to copy").font(.system(size: 10.5)).foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .background(PanelBackground())
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onExitCommand { close() }
    }

    private func row(_ item: History.Item) -> some View {
        HStack(spacing: 10) {
            Group {
                if let c = item.color {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: c.nsColor))
                } else if let t = item.thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.mode.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isSecret ? "Secret ••••••" : item.title.oneLine)
                    .font(.system(size: 12.5))
                    .lineLimit(2)
                Text([item.mode.title, item.source, Self.relative.localizedString(for: item.date, relativeTo: Date())]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if copiedID == item.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func copy(_ item: History.Item) {
        Clipboard.write(item.payload, secret: item.isSecret)
        Sound.shared.play(.copy)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if copiedID == item.id { copiedID = nil } }
        }
    }
}
