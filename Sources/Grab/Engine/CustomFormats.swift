import Foundation

/// A format you add yourself to the ⇥ list: a text template like `[{title}]({url})`,
/// or a Shortcut that gets the grab and hands back what to copy.
struct CustomFormat: Codable, Identifiable, Equatable {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case text, code, link, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: "Text"
            case .code: "Code"
            case .link: "Links"
            case .image: "Images"
            }
        }
    }

    var id = UUID()
    var name: String
    var template: String
    /// Run this Shortcut instead of filling in the template.
    var shortcut: String?
    var targets: Set<Target>

    var formatID: String { "custom." + id.uuidString }

    static let tokens: [(String, String)] = [
        ("{text}", "What you grabbed (a link's text for links)"),
        ("{url}", "The link, or the page's address"),
        ("{title}", "Page or window title"),
        ("{app}", "App name"),
        ("{date}", "Today, 2026-10-04"),
        ("{time}", "Now, 14:05"),
        ("{lang}", "Code language"),
        ("{file}", "File name, for code"),
        ("{line}", "First line number, for code"),
    ]

    static let filters: [(String, String)] = [
        ("|upper", "UPPERCASE"), ("|lower", "lowercase"), ("|oneline", "one line"), ("|trim", "no outer spaces"),
        ("|slug", "a-url-slug"), ("|json", "a JSON string"), ("|url", "percent-encoded"),
    ]

    static let examples: [CustomFormat] = [
        CustomFormat(name: "Markdown link", template: "[{title}]({url})", targets: [.text, .link]),
        CustomFormat(name: "Quote with app", template: "“{text|oneline}” — {app}", targets: [.text]),
        CustomFormat(name: "Code + file", template: "{file}:{line}\n```{lang}\n{text}\n```", targets: [.code]),
        CustomFormat(name: "Slug", template: "{text|slug}", targets: [.text]),
        CustomFormat(name: "Dated note", template: "- {date} {time}: {text|oneline} ({url})", targets: [.text, .link]),
    ]
}

enum Template {
    /// Fills `{token}` and `{token|filter|filter}` from `values`. Unknown tokens are left as typed;
    /// known ones with no value become empty. `\n` and `\t` in the template are newline and tab.
    static func render(_ template: String, values: [String: String]) -> String {
        let t = template.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        var out = ""
        var i = t.startIndex
        while i < t.endIndex {
            if t[i] == "{", let close = t[i...].firstIndex(of: "}") {
                let inner = t[t.index(after: i)..<close]
                var parts = inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let name = parts.removeFirst().lowercased()
                if let value = values[name] {
                    out += parts.reduce(value) { apply($1.lowercased(), to: $0) }
                    i = t.index(after: close)
                    continue
                }
            }
            out.append(t[i])
            i = t.index(after: i)
        }
        return out
    }

    static func apply(_ filter: String, to s: String) -> String {
        switch filter {
        case "upper": return s.uppercased()
        case "lower": return s.lowercased()
        case "oneline": return Formats.oneLine(s)
        case "trim": return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case "slug":
            return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        case "json": return Formats.jsonString(s)
        case "url": return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? s
        default: return s
        }
    }

    static func values(text: String, url: URL?, title: String?, app: String?, language: String? = nil,
                       file: URL? = nil, line: Int? = nil, now: Date = Date()) -> [String: String] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        return [
            "text": text,
            "url": url?.absoluteString ?? "",
            "title": title ?? "",
            "app": app ?? "",
            "date": day.string(from: now),
            "time": clock.string(from: now),
            "lang": language ?? "",
            "file": file?.lastPathComponent ?? "",
            "line": line.map(String.init) ?? "",
        ]
    }
}

/// Runs a Shortcut from the Shortcuts app with the grab as its input.
enum ShortcutRunner {
    enum Output { case text(String), image(Data) }

    /// Names of your shortcuts, for the picker in Settings.
    static func list() async -> [String] {
        await Task.detached(priority: .utility) {
            guard let out = run(["list"], timeout: 8) else { return [] }
            return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
    }

    static func run(_ name: String, input: Data, ext: String) async -> Output? {
        await Task.detached(priority: .userInitiated) { () -> Output? in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Grab-shortcut-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let inURL = dir.appendingPathComponent("input.\(ext)")
            let outURL = dir.appendingPathComponent("output")
            guard (try? input.write(to: inURL)) != nil else { return nil }
            guard run(["run", name, "--input-path", inURL.path, "--output-path", outURL.path], timeout: 30) != nil,
                  let data = try? Data(contentsOf: outURL), !data.isEmpty else { return nil }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image(data) }
            guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return .text(s)
        }.value
    }

    /// `/usr/bin/shortcuts` with a deadline; nil if it fails or runs too long.
    private static func run(_ args: [String], timeout: TimeInterval) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        // Drain the pipe as it fills, so a chatty shortcut can't stall on a full buffer.
        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        guard (try? task.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        task.waitUntilExit()
        guard Date() < deadline, task.terminationStatus == 0 else { return nil }
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return String(data: collected.data, encoding: .utf8) ?? ""
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
