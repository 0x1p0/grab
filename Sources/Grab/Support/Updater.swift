import AppKit
import Security
import SwiftUI

/// Checks GitHub Releases for a newer Grab (at most once a day, when macOS finds a
/// good moment) and installs it when you say so. A download only replaces Grab if it's
/// signed by the same developer as the copy that's running.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let repository = "0x1p0/grab"

    struct Release: Equatable {
        var version: String
        var notes: String
        var download: URL
        var page: URL?
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var available: Release?
    private(set) var state: State = .idle
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    #if DEBUG
    /// A local feed for testing (`updatefeed:<url>`).
    @ObservationIgnored var debugFeed: URL?
    #endif

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    // MARK: Schedule

    func applySettings() {
        if Settings.shared.checkForUpdates {
            guard scheduler == nil else { return }
            let s = NSBackgroundActivityScheduler(identifier: "com.thirteen.Grab.updates")
            s.repeats = true
            s.interval = 24 * 3600
            s.tolerance = 4 * 3600
            s.qualityOfService = .utility
            s.schedule { done in
                Task { @MainActor in
                    await Updater.shared.check(userInitiated: false)
                    done(.finished)
                }
            }
            scheduler = s
        } else {
            scheduler?.invalidate()
            scheduler = nil
        }
    }

    // MARK: Check

    private var feed: URL {
        #if DEBUG
        if let debugFeed { return debugFeed }
        #endif
        return URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    func check(userInitiated: Bool) async {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Grab/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parse(data) else {
            state = userInitiated ? .failed("Couldn't reach the update server") : .idle
            if userInitiated { Panels.shared.showUpdate() }
            return
        }
        if Self.isNewer(release.version, than: Self.currentVersion),
           userInitiated || release.version != Settings.shared.skippedVersion {
            available = release
            state = .idle
            Panels.shared.showUpdate()
        } else {
            available = nil
            state = userInitiated ? .upToDate : .idle
            if userInitiated { Panels.shared.showUpdate() }
        }
    }

    /// GitHub's "latest release" JSON: the tag, the notes, and the .zip to install.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let zip = assets.compactMap { a -> URL? in
            guard let name = a["name"] as? String, name.lowercased().hasSuffix(".zip"),
                  let s = a["browser_download_url"] as? String else { return nil }
            return URL(string: s)
        }.first
        guard let zip else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: obj["body"] as? String ?? "", download: zip,
                       page: (obj["html_url"] as? String).flatMap(URL.init(string:)))
    }

    /// "1.10.0" is newer than "1.9.2". Pre-release suffixes ("1.2.0-beta") count as older than the release.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], Bool) {
            let core = v.split(separator: "-", maxSplits: 1)
            let nums = core.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return (nums, core.count > 1)
        }
        let (x, xPre) = parts(a), (y, yPre) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return yPre && !xPre
    }

    func skip(_ r: Release) {
        Settings.shared.skippedVersion = r.version
        available = nil
    }

    // MARK: Install

    func install(_ r: Release) async {
        state = .downloading
        do {
            let current = Bundle.main.bundleURL
            let fm = FileManager.default
            guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw UpdateError("Grab can't replace itself in \(current.deletingLastPathComponent().path). Download it from the release page instead.")
            }
            // Same volume as the app, so the swap is a rename.
            let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
            defer { try? fm.removeItem(at: work) }
            let (tmp, response) = try await URLSession(configuration: .ephemeral).download(from: r.download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download didn't work") }
            let zip = work.appendingPathComponent("Grab.zip")
            try fm.moveItem(at: tmp, to: zip)
            state = .installing
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try await Self.unzip(zip, to: unpacked)
            guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The download has no app in it")
            }
            try Self.verify(app, version: r.version)
            _ = try fm.replaceItemAt(current, withItemAt: app)
            relaunch(current)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    struct UpdateError: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    nonisolated private static func unzip(_ zip: URL, to dir: URL) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dir.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the update") }
        }.value
    }

    /// The certificate official releases are signed with (SHA-1 of the "Grab Release" certificate).
    nonisolated static let releaseCertificate = "3f7a72209f972742d7f85825176396efc194da89"

    /// The new app must be Grab, the version we expect, and signed either by whoever signed this
    /// copy or with Grab's release certificate (so a copy you built yourself can still update to
    /// an official release).
    nonisolated static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't Grab")
        }
        let found = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard found == version else { throw UpdateError("The download is version \(found), expected \(version)") }

        var me: SecCode?
        var staticMe: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("This copy of Grab isn't signed, so updates can't be checked. Download it from the release page.")
        }
        // An ad-hoc signature names one exact build; no other build can match it.
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
           flags & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0 {
            throw UpdateError("This copy of Grab was built locally, so it can't verify downloads. Download the update from the release page.")
        }
        try checkSignature(of: app, against: [requirement] + (releaseRequirement().map { [$0] } ?? []))
    }

    /// Passes if the app is validly signed and meets any one of the requirements.
    nonisolated static func checkSignature(of app: URL, against requirements: [SecRequirement]) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download isn't signed")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        for r in requirements where SecStaticCodeCheckValidityWithErrors(code, flags, r, nil) == errSecSuccess { return }
        throw UpdateError("The download isn't signed by Grab's developer, so it wasn't installed")
    }

    nonisolated static func releaseRequirement() -> SecRequirement? {
        var r: SecRequirement?
        let text = "identifier \"com.thirteen.Grab\" and certificate root = H\"\(releaseCertificate)\"" as CFString
        return SecRequirementCreateWithString(text, [], &r) == errSecSuccess ? r : nil
    }

    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// "Grab 1.3 is here": notes, and buttons to install, skip or wait.
struct UpdateView: View {
    @State private var updater = Updater.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let r = updater.available {
                ScrollView {
                    Text((try? AttributedString(markdown: r.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(r.notes))
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            if case .failed(let why) = updater.state {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let r = updater.available {
                    Button("Skip This Version") { updater.skip(r); close() }
                    Spacer()
                    Button("Later", action: close)
                    Button {
                        Task { await updater.install(r) }
                    } label: {
                        if updater.state == .downloading || updater.state == .installing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(updater.state == .downloading ? "Downloading…" : "Installing…") }
                        } else {
                            Text("Install and Relaunch")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.state == .downloading || updater.state == .installing)
                } else {
                    Spacer()
                    Button("OK", action: close).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular)
        }
        .padding(20)
        .padding(.top, 10)
        .frame(width: 420)
    }

    private var title: String {
        if let r = updater.available { return "Grab \(r.version) is here" }
        if updater.state == .upToDate { return "You're up to date" }
        if updater.state == .checking { return "Checking…" }
        return "Updates"
    }

    private var subtitle: String {
        if updater.available != nil { return "You have \(Updater.currentVersion). Your settings and permissions carry over." }
        return "Grab \(Updater.currentVersion) is the newest version."
    }
}
