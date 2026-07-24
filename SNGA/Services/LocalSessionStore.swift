import Foundation

actor LocalSessionStore: SessionStore {
    static let shared = LocalSessionStore()

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
                .appending(path: "Sessions", directoryHint: .isDirectory)
        }
    }

    func cookies(for accountID: AccountID) throws -> [SessionCookie] {
        let url = fileURL(for: accountID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode([SessionCookie].self, from: data)
        let valid = stored.filter { !$0.isExpired }
        if valid.count != stored.count {
            try save(cookies: valid, for: accountID)
        }
        return valid
    }

    func save(cookies: [SessionCookie], for accountID: AccountID) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(cookies)
        let url = fileURL(for: accountID)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func remove(accountID: AccountID) throws {
        let url = fileURL(for: accountID)
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

    private func fileURL(for accountID: AccountID) -> URL {
        directoryURL.appending(path: "\(accountID.description).json", directoryHint: .notDirectory)
    }
}
