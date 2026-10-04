import CryptoKit
import Foundation
import Security

/// "Keep history": grabs saved between launches, encrypted with a key that lives in
/// your keychain. Off by default; secrets are never saved.
///
/// The file is a list of sealed records, each `[UInt32 length][AES-GCM box]`, so a new
/// grab is one append rather than a rewrite.
final class HistoryVault: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var id: UUID
        var date: Date
        var mode: Int
        var title: String
        /// text · code · link · file · color · image
        var kind: String
        var text: String?
        var color: [Double]?
        var image: Data?
        var pointSize: [Double]?
        var thumbnail: Data?
        var appName: String?
        var bundleID: String?
        var source: String?
        var sourceURL: String?
    }

    let url: URL
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "app.grab.vault", qos: .utility)

    init(url: URL, key: SymmetricKey) {
        self.url = url
        self.key = key
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Grab", isDirectory: true).appendingPathComponent("History.grabvault")
    }

    // MARK: Reading and writing

    func append(_ r: Record) {
        queue.async { [self] in
            guard let frame = seal(r) else { return }
            ensureDirectory()
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: frame)
            } else {
                try? frame.write(to: url, options: [.atomic])
                protect()
            }
        }
    }

    /// Everything that can be opened with our key, oldest first. Damaged records are skipped.
    func load() -> [Record] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            var out: [Record] = []
            var i = data.startIndex
            while i + 4 <= data.endIndex {
                let len = Int(data[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
                i += 4
                guard len > 0, i + len <= data.endIndex else { break }
                if let box = try? AES.GCM.SealedBox(combined: data[i..<i + len]),
                   let plain = try? AES.GCM.open(box, using: key),
                   let r = try? JSONDecoder().decode(Record.self, from: plain) {
                    out.append(r)
                }
                i += len
            }
            return out
        }
    }

    /// Replaces the file with exactly these records (after pruning or deleting).
    func rewrite(_ records: [Record]) {
        queue.async { [self] in
            guard !records.isEmpty else { try? FileManager.default.removeItem(at: url); return }
            var data = Data()
            for r in records { if let f = seal(r) { data.append(f) } }
            ensureDirectory()
            try? data.write(to: url, options: [.atomic])
            protect()
        }
    }

    func erase() {
        queue.sync { _ = try? FileManager.default.removeItem(at: url) }
    }

    /// Waits for pending writes (tests, and before quitting).
    func flush() { queue.sync {} }

    private func seal(_ r: Record) -> Data? {
        guard let plain = try? JSONEncoder().encode(r), let box = try? AES.GCM.seal(plain, using: key), let combined = box.combined else { return nil }
        var frame = Data()
        withUnsafeBytes(of: UInt32(combined.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(combined)
        return frame
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Readable by you only.
    private func protect() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Key

    /// The history key, from the keychain; made the first time Keep History is turned on.
    enum Keychain {
        private static let service = "Grab History"
        private static let account = "history-encryption-key"

        static func key(create: Bool) -> SymmetricKey? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 {
                return SymmetricKey(data: data)
            }
            guard create else { return nil }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: "Grab History",
                kSecAttrDescription as String: "Encrypts Grab's saved clipboard history",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ]
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
        }

        static func delete() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
