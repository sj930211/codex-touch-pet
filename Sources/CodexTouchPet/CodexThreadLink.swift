import Foundation

enum CodexThreadLink {
    static func url(threadID: String, hostID: String = "local") -> URL? {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHostID = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !normalizedHostID.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(normalizedThreadID)"
        components.queryItems = [URLQueryItem(name: "hostId", value: normalizedHostID)]
        return components.url
    }
}
