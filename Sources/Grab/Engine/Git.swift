import Foundation

/// Permalinks for code: `https://github.com/owner/repo/blob/<commit>/path#L12-L30`.
/// Reads `.git` directly (config, HEAD, refs), never runs git, and caches per repository.
enum Git {
    struct Repo {
        let root: URL
        let web: URL
        let host: String
        let commit: String?
    }

    private static let lock = NSLock()
    private static var repos: [String: Repo?] = [:]

    /// "GitHub link", "GitLab link"… when the file lives in a repository with a known web host.
    static func remoteHost(for file: URL, lines: ClosedRange<Int>) -> String? {
        guard let r = repo(for: file), r.commit != nil else { return nil }
        return "\(r.host) link"
    }

    static func permalink(file: URL, lines: ClosedRange<Int>) -> URL? {
        guard let r = repo(for: file), let commit = r.commit else { return nil }
        let rel = String(file.standardizedFileURL.path.dropFirst(r.root.standardizedFileURL.path.count + 1))
        let path = rel.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let anchor: String
        switch r.host {
        case "GitLab":
            anchor = lines.lowerBound == lines.upperBound ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)-\(lines.upperBound)"
            return URL(string: "\(r.web.absoluteString)/-/blob/\(commit)/\(path)#\(anchor)")
        case "Bitbucket":
            anchor = lines.lowerBound == lines.upperBound ? "lines-\(lines.lowerBound)" : "lines-\(lines.lowerBound):\(lines.upperBound)"
            return URL(string: "\(r.web.absoluteString)/src/\(commit)/\(path)#\(anchor)")
        default:
            anchor = lines.lowerBound == lines.upperBound ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)-L\(lines.upperBound)"
            return URL(string: "\(r.web.absoluteString)/blob/\(commit)/\(path)#\(anchor)")
        }
    }

    static func repo(for file: URL) -> Repo? {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        var visited: [String] = []
        while dir.path != "/" && !dir.path.isEmpty {
            lock.lock()
            if let cached = repos[dir.path] {
                lock.unlock()
                for v in visited { lock.lock(); repos[v] = cached; lock.unlock() }
                return cached
            }
            lock.unlock()
            visited.append(dir.path)
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let repo = read(root: dir, dotGit: dotGit, isDirectory: isDir.boolValue)
                lock.lock()
                for v in visited { repos[v] = repo }
                lock.unlock()
                return repo
            }
            dir = dir.deletingLastPathComponent()
        }
        lock.lock()
        for v in visited { repos[v] = .some(nil) }
        lock.unlock()
        return nil
    }

    private static func read(root: URL, dotGit: URL, isDirectory: Bool) -> Repo? {
        var gitDir = dotGit
        if !isDirectory {
            // Worktrees and submodules: ".git" is a file pointing at the real directory.
            guard let s = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = s.components(separatedBy: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p).standardizedFileURL
        }
        var common = gitDir
        if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            let p = c.trimmingCharacters(in: .whitespacesAndNewlines)
            common = p.hasPrefix("/") ? URL(fileURLWithPath: p) : gitDir.appendingPathComponent(p).standardizedFileURL
        }
        guard let config = try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8),
              let remote = originURL(config), let (web, host) = webURL(remote) else { return nil }
        return Repo(root: root, web: web, host: host, commit: head(gitDir: gitDir, common: common))
    }

    /// The URL of "origin", or of the first remote.
    static func originURL(_ config: String) -> String? {
        var current: String?
        var urls: [(String, String)] = []
        for raw in config.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.range(of: #"^\[remote "([^"]+)"\]"#, options: .regularExpression) != nil
                    ? line.components(separatedBy: "\"")[1] : nil
            } else if let name = current, line.hasPrefix("url"), let eq = line.firstIndex(of: "=") {
                urls.append((name, line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return urls.first { $0.0 == "origin" }?.1 ?? urls.first?.1
    }

    /// git@github.com:owner/repo.git → https://github.com/owner/repo
    static func webURL(_ remote: String) -> (URL, String)? {
        var r = remote
        if r.hasSuffix(".git") { r.removeLast(4) }
        var host = "", path = ""
        if let m = r.range(of: #"^[\w.-]+@([\w.-]+):(.+)$"#, options: .regularExpression), m.lowerBound == r.startIndex {
            let afterAt = r[r.index(after: r.firstIndex(of: "@")!)...]
            host = String(afterAt.prefix { $0 != ":" })
            path = String(afterAt.drop { $0 != ":" }.dropFirst())
        } else if let u = URL(string: r), let h = u.host {
            host = h
            path = String(u.path.drop { $0 == "/" })
        } else {
            return nil
        }
        guard !path.isEmpty else { return nil }
        let name: String
        if host.contains("github") { name = "GitHub" }
        else if host.contains("gitlab") { name = "GitLab" }
        else if host.contains("bitbucket") { name = "Bitbucket" }
        else { return nil }
        guard let url = URL(string: "https://\(host)/\(path)") else { return nil }
        return (url, name)
    }

    private static func head(gitDir: URL, common: URL) -> String? {
        guard let h = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard h.hasPrefix("ref:") else { return h.count >= 40 ? h : nil }
        let ref = h.dropFirst(4).trimmingCharacters(in: .whitespaces)
        for base in [gitDir, common] {
            if let sha = try? String(contentsOf: base.appendingPathComponent(ref), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), sha.count >= 40 { return sha }
        }
        if let packed = try? String(contentsOf: common.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.components(separatedBy: "\n") where line.hasSuffix(" " + ref) {
                return String(line.prefix { $0 != " " })
            }
        }
        return nil
    }
}
