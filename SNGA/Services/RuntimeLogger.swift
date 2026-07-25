import Foundation

enum RuntimeLogSettings {
    static let enabledKey = "runtimeLog.enabled"
    private static let directoryBookmarkKey = "runtimeLog.directoryBookmark"
    private static let directoryPathKey = "runtimeLog.directoryPath"

    static var defaultDirectoryURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appending(path: "SNGA", directoryHint: .isDirectory)
            .appending(path: "Logs", directoryHint: .isDirectory)
    }

    static var selectedDirectoryURL: URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: directoryBookmarkKey) else {
            return nil
        }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    static var outputDirectoryURL: URL {
        selectedDirectoryURL ?? defaultDirectoryURL
    }

    static var displayPath: String {
        selectedDirectoryURL?.path
            ?? UserDefaults.standard.string(forKey: directoryPathKey)
            ?? defaultDirectoryURL.path
    }

    static func selectDirectory(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: directoryBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: directoryPathKey)
    }

    static func useDefaultDirectory() {
        UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
        UserDefaults.standard.removeObject(forKey: directoryPathKey)
    }
}

enum RuntimeLogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

actor RuntimeLogger {
    static let shared = RuntimeLogger()

    func log(
        _ level: RuntimeLogLevel = .info,
        category: String,
        _ message: String
    ) {
        guard UserDefaults.standard.bool(forKey: RuntimeLogSettings.enabledKey) else {
            return
        }

        let directoryURL = RuntimeLogSettings.outputDirectoryURL
        let isCustomDirectory = RuntimeLogSettings.selectedDirectoryURL != nil
        let didAccess = isCustomDirectory
            ? directoryURL.startAccessingSecurityScopedResource()
            : false
        defer {
            if didAccess {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appending(
                path: "SNGA-\(dayFormatter.string(from: Date())).log"
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(Self.redacted(message))\n"
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            // 日志写入失败不能影响应用的正常业务流程。
        }
    }

    nonisolated static func sanitizedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redacted(url.absoluteString)
        }
        let sensitiveNames = Set([
            "access_token", "access_uid", "auth", "token",
            "ngaPassportCid", "ngaPassportUid"
        ])
        components.queryItems = components.queryItems?.map { item in
            guard sensitiveNames.contains(item.name) else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return components.string.map(redacted) ?? redacted(url.absoluteString)
    }

    nonisolated static func redacted(_ value: String) -> String {
        let pattern = #"(?i)\b(access_token|access_uid|auth|authorization|cookie|ngaPassportCid|ngaPassportUid|token)\s*([=:]\s*)("[^"]*"|'[^']*'|[^\s&,;]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1$2<redacted>"
        )
    }

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
