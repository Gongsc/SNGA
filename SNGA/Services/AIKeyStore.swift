import Foundation

protocol AIKeyStore: Sendable {
    func apiKey() async throws -> String?
    func save(apiKey: String) async throws
    func removeAPIKey() async throws
}

/// API Key 存在应用沙盒里的一个 0600 文件中，不进 macOS 钥匙串。
///
/// 本项目一律不用钥匙串。原因不是安全性，是它会要人输系统密码：本地构建每次的签名
/// 都不一样，系统会为此弹出「SNGA 想要使用您钥匙串中存储的机密信息」并等一个登录密码，
/// 构建和跑 UI 测试都会撞上，自动化里没人替它填。
///
/// 代价是保护强度降到「沙盒 + 文件权限」这一档，和会话 Cookie 同级 ——
/// 存法也照抄 `LocalSessionStore`：目录 0700、文件 0600、原子写。
actor LocalAIKeyStore: AIKeyStore {
    static let shared = LocalAIKeyStore()

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directoryURL = applicationSupport
                .appending(path: "SNGA", directoryHint: .isDirectory)
                .appending(path: "AI", directoryHint: .isDirectory)
        }
    }

    func apiKey() throws -> String? {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let stored = String(data: data, encoding: .utf8) else {
            throw AIServiceError.keyStorage("保存的 API Key 不是有效的文本")
        }
        let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func save(apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try removeAPIKey()
            return
        }
        try ensureDirectory()
        let url = fileURL
        try Data(normalized.utf8).write(to: url, options: .atomic)
        // 原子写换的是一个新文件，权限要在写完之后再设。
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func removeAPIKey() throws {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    private var fileURL: URL {
        directoryURL.appending(
            path: "openai-compatible-api-key",
            directoryHint: .notDirectory
        )
    }
}

#if DEBUG
actor InMemoryAIKeyStore: AIKeyStore {
    private var storedKey: String?

    init(apiKey: String? = nil) {
        self.storedKey = apiKey
    }

    func apiKey() -> String? {
        storedKey
    }

    func save(apiKey: String) {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        storedKey = normalized.isEmpty ? nil : normalized
    }

    func removeAPIKey() {
        storedKey = nil
    }
}
#endif
