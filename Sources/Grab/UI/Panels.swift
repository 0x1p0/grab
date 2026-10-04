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
            let p = FloatingPanel(size: NSSize(width: 560, height: 620), title: "Grab History")
            p.minSize = NSSize(width: 420, height: 320)
            p.host(HistoryView(close: { [weak p] in p?.close() }))
            p.center()
            historyPanel = p
            // Closed means gone: no window or view kept around in memory.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.historyPanel?.contentView = nil
                    self?.historyPanel = nil
                }
            }
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

/// App icons for history sections, looked up once each.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(_ bundleID: String?) -> NSImage {
        guard let id = bundleID else { return NSWorkspace.shared.icon(for: .application) }
        if let i = cache[id] { return i }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icon.size = NSSize(width: 32, height: 32)
        cache[id] = icon
        return icon
    }
}

private struct HistoryView: View {
    let close: () -> Void
    private let history = History.shared
    @State private var query = ""
    @State private var filter: History.Kind?
    @State private var byApp = UserDefaults.standard.object(forKey: "historyByApp") as? Bool ?? true
    @State private var selection: UUID?
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool

    private var filtered: [History.Item] {
        let terms = query.lowercased().split(separator: " ")
        return history.items.filter { item in
            if let filter, item.kind != filter { return false }
            guard !terms.isEmpty else { return true }
            let hay = item.searchText.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let bundleID: String?
        let showsIcon: Bool
        let items: [History.Item]
    }

    private var sections: [Section] {
        let list = filtered
        if byApp {
            return history.byApp(list).map { Section(id: "app." + $0.app, title: $0.app, bundleID: $0.bundleID, showsIcon: true, items: $0.items) }
        }
        let cal = Calendar.current
        var today: [History.Item] = [], yesterday: [History.Item] = [], earlier: [History.Item] = []
        for i in list {
            if cal.isDateInToday(i.date) { today.append(i) } else if cal.isDateInYesterday(i.date) { yesterday.append(i) } else { earlier.append(i) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)].filter { !$0.1.isEmpty }
            .map { Section(id: "time." + $0.0, title: $0.0, bundleID: nil, showsIcon: false, items: $0.1) }
    }

    private var flat: [History.Item] { sections.flatMap(\.items) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if history.items.isEmpty {
                empty
            } else if flat.isEmpty {
                Spacer()
                Text("No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                list
            }
            Divider().opacity(0.4)
            footer
        }
        .background(PanelBackground())
        .ignoresSafeArea()
        .onAppear {
            searchFocused = true
            selection = flat.first?.id
        }
        .onChange(of: query) { _, _ in selection = flat.first?.id }
        .onChange(of: filter) { _, _ in selection = flat.first?.id }
    }

    // Search, filters and grouping.
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you've grabbed", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { copySelected(andClose: true); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(keys: [.delete], phases: .down) { press in
                        guard press.modifiers.contains(.command), let id = selection else { return .ignored }
                        delete(id)
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 6) {
                chip(nil, "All", "square.grid.2x2", count: history.items.count)
                ForEach(History.Kind.allCases) { k in
                    let n = history.items.filter { $0.kind == k }.count
                    if n > 0 { chip(k, k.title, k.symbol, count: n) }
                }
                Spacer(minLength: 0)
                Picker("", selection: $byApp) {
                    Image(systemName: "square.stack.3d.up").help("Group by app").tag(true)
                    Image(systemName: "clock").help("Group by time").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: byApp) { _, v in UserDefaults.standard.set(v, forKey: "historyByApp") }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private func chip(_ kind: History.Kind?, _ title: String, _ symbol: String, count: Int) -> some View {
        let on = filter == kind
        return Button { filter = kind } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(on ? .white.opacity(0.8) : .secondary)
            }
            .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing))
                                          : AnyShapeStyle(Color.primary.opacity(0.07))))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { item in
                                HistoryRow(item: item, selected: selection == item.id, copied: copiedID == item.id,
                                           showsApp: !byApp, copy: { copy(item, andClose: false) }, delete: { delete(item.id) })
                                    .id(item.id)
                                    .onTapGesture(count: 2) { copy(item, andClose: true) }
                                    .onTapGesture { selection = item.id; copy(item, andClose: false) }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) } }
            }
        }
    }

    private func sectionHeader(_ s: Section) -> some View {
        HStack(spacing: 7) {
            if s.showsIcon {
                Image(nsImage: AppIcons.icon(s.bundleID)).resizable().frame(width: 16, height: 16)
            }
            Text(s.title).font(.system(size: 11.5, weight: .semibold))
            Text("\(s.items.count)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(PanelBackground().opacity(0.98))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            MascotIdle(kind: MascotKind(rawValue: Settings.shared.mascot) ?? .snap).frame(height: 64)
            Text("Nothing grabbed yet").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 4) {
                Text("Hold")
                KeyView(key: "⌥", size: 10)
                Text("over anything and press")
                KeyView(key: "C", size: 10)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                Label("copy", systemImage: "return")
                Label("move", systemImage: "arrow.up.arrow.down")
                Label("delete", systemImage: "delete.left")
            }
            .labelStyle(HintLabelStyle())
            Spacer()
            Text("Memory only").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Button("Clear All") {
                history.clear()
                selection = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .disabled(history.items.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func move(_ delta: Int) {
        let ids = flat.map(\.id)
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, i + delta))]
    }

    private func copySelected(andClose: Bool) {
        guard let id = selection ?? flat.first?.id, let item = history.items.first(where: { $0.id == id }) else { return }
        copy(item, andClose: andClose)
    }

    private func copy(_ item: History.Item, andClose: Bool) {
        Clipboard.write(item.payload, secret: item.isSecret)
        Sound.shared.play(.copy)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copiedID = item.id }
        if andClose {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { close() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { withAnimation { if copiedID == item.id { copiedID = nil } } }
        }
    }

    private func delete(_ id: UUID) {
        let ids = flat.map(\.id)
        let i = ids.firstIndex(of: id)
        history.remove(id)
        let rest = flat.map(\.id)
        selection = i.flatMap { rest.isEmpty ? nil : rest[min($0, rest.count - 1)] }
    }
}

private struct HintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9.5, weight: .semibold))
            configuration.title.font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }
}

/// One grab: what it is at a glance, where it came from, and when.
private struct HistoryRow: View {
    let item: History.Item
    let selected: Bool
    let copied: Bool
    let showsApp: Bool
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 11) {
            leading
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                primary
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if hovering {
                HStack(spacing: 2) {
                    Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }.help("Copy")
                    Button(action: delete) { Image(systemName: "trash").frame(width: 22, height: 22) }.help("Remove from history")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var tint: [Color] { Theme.colors(for: item.mode, sample: item.color) }

    @ViewBuilder private var leading: some View {
        if let c = item.color {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: c.nsColor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        } else if let t = item.thumbnail {
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
        } else if item.kind == .files, case .file(let u) = item.payload {
            Image(nsImage: FileIcon.icon(for: u)).resizable().padding(2)
        } else {
            ZStack {
                LinearGradient(colors: tint.map { $0.opacity(0.9) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: item.kind == .links ? "link" : item.kind == .codes ? "qrcode" : (item.mode == .text ? "text.quote" : item.mode.symbol))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var primary: some View {
        if item.isSecret {
            Text("Secret ••••••").font(.system(size: 12.5, weight: .medium))
        } else if item.kind == .links, case .link(let u) = item.payload {
            HStack(spacing: 0) {
                Text(u.host ?? u.absoluteString).font(.system(size: 12.5, weight: .semibold))
                Text(u.path.count > 1 ? u.path : "").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } else if item.kind == .colors {
            Text(item.title).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
        } else if item.kind == .files, case .file(let u) = item.payload {
            Text(u.lastPathComponent).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        } else if let t = item.text, t.uppercased().hasPrefix("WIFI:") {
            // Never show the password in a list.
            Text("Wi-Fi “\(Formats.wifi(t).network ?? "network")”").font(.system(size: 12.5, weight: .semibold))
        } else {
            let text = item.text ?? item.title
            Text(Formats.oneLine(text).trimmingCharacters(in: CharacterSet(charactersIn: "“”")))
                .font(.system(size: 12.5, design: looksLikeCode(text) ? .monospaced : .default))
                .lineLimit(2)
        }
    }

    private func looksLikeCode(_ t: String) -> Bool {
        t.contains("{") || t.contains("func ") || t.contains("=>") || t.contains("();")
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsApp, let a = item.appName { parts.append(a) }
        if item.kind == .files, case .file(let u) = item.payload {
            parts.append((u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        } else if let s = item.source {
            parts.append(s)
        }
        parts.append(Self.when(item.date))
        return parts.joined(separator: " · ")
    }

    static func when(_ d: Date) -> String {
        let ago = Date().timeIntervalSince(d)
        return ago < 60 ? "just now" : relative.localizedString(for: d, relativeTo: Date())
    }
}

#if DEBUG
/// Fills history with sample grabs and snapshots the window (debug hook `historystill:<path>`).
enum HistoryDebug {
    @MainActor
    static func snapshot(to path: String) {
        if History.shared.items.isEmpty {
            func add(_ mode: GrabMode, _ payload: Payload, _ title: String, app: String, bundle: String, source: String?, color: RGBAColor? = nil, minutesAgo: Double = 0) {
                var i = History.Item(mode: mode, payload: payload, title: title, thumbnail: nil, color: color)
                i.appName = app
                i.bundleID = bundle
                i.source = source
                History.shared.add(i)
            }
            add(.text, .text("Great work rarely comes from doing more. It comes from removing everything that isn't the work."), "“Great work rarely comes from doing more…”", app: "Safari", bundle: "com.apple.Safari", source: "The quiet art of focus")
            add(.link, .link(URL(string: "https://northwind.design/studio")!), "northwind.design/studio", app: "Safari", bundle: "com.apple.Safari", source: "Moodboard")
            add(.color, .color(RGBAColor(r: 0.93, g: 0.43, b: 0.16), "#ED6E2A"), "#ED6E2A", app: "Figma", bundle: "com.figma.Desktop", source: "Brand colors", color: RGBAColor(r: 0.93, g: 0.43, b: 0.16))
            add(.text, .text("func render(_ post: Post) -> some View {\n    PinnedRow(post)\n}"), "func render(_ post: Post) -> some View {", app: "Xcode", bundle: "com.apple.dt.Xcode", source: "Feed.swift")
            add(.file, .file(URL(fileURLWithPath: "/Users/me/Documents/Launch Plan.pdf")), "Launch Plan.pdf", app: "Finder", bundle: "com.apple.finder", source: nil)
            add(.qr, .code("WIFI:T:WPA;S:Studio;P:sunset-42;;"), "Wi-Fi “Studio”", app: "Preview", bundle: "com.apple.Preview", source: "poster.png")
            add(.text, .text("npm run build"), "npm run build", app: "Terminal", bundle: "com.apple.Terminal", source: nil)
        }
        Panels.shared.showHistory()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let w = NSApp.windows.first(where: { $0.title == "Grab History" }), let v = w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
